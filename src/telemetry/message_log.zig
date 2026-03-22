//! Message logging — persistent audit trail of all conversation messages.
//!
//! Writes one markdown file per message to workspace/messages/ with frontmatter.
//!
//! Filename: YYYYMMDD_HHMMSS_ffffff_+0000.md (UTC, 6-digit microseconds)
//!
//! Format:
//!   ---
//!   timestamp: "2026-03-21T15:24:39.701115Z"
//!   role: "user" | "assistant" | "system"
//!   session_id: "optional-session-id" | null
//!   ---
//!   <message content as plaintext>
//!
//! This is append-only, crash-safe, and designed for later analysis
//! (token counting, memory generation, insights, etc.).

const std = @import("std");
const fs_compat = @import("../fs_compat.zig");

pub const MessageLogger = struct {
    allocator: std.mem.Allocator,
    workspace_dir: []const u8,
    messages_dir: []const u8,
    enabled: bool = false,

    const Self = @This();

    /// Initialize message logger.
    pub fn init(allocator: std.mem.Allocator, workspace_dir: []const u8, enabled: bool) !Self {
        const messages_dir = if (enabled)
            try std.fs.path.join(allocator, &.{ workspace_dir, "messages" })
        else
            try allocator.dupe(u8, workspace_dir); // dummy, won't be used

        return Self{
            .allocator = allocator,
            .workspace_dir = try allocator.dupe(u8, workspace_dir),
            .messages_dir = messages_dir,
            .enabled = enabled,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.workspace_dir);
        self.allocator.free(self.messages_dir);
    }



    /// Ensure the messages directory and the date subdirectory for a file exist.
    fn ensureMessagesDir(self: *Self, file_path: []const u8) !void {
        // Ensure top-level messages directory exists
        std.fs.makeDirAbsolute(self.messages_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Also ensure the parent directory of the file (date subdir) exists
        if (std.fs.path.dirname(file_path)) |dir| {
            std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
    }

    /// Escape a string for YAML frontmatter value (JSON-style escaping).
    fn escapeYamlString(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
        var list = std.ArrayListUnmanaged(u8){};
        try list.ensureTotalCapacity(allocator, s.len + 2);
        try list.append(allocator, '"');
        for (s) |c| {
            switch (c) {
                '"' => try list.appendSlice(allocator, "\\\""),
                '\\' => try list.appendSlice(allocator, "\\\\"),
                '\n' => try list.appendSlice(allocator, "\\n"),
                '\r' => try list.appendSlice(allocator, "\\r"),
                '\t' => try list.appendSlice(allocator, "\\t"),
                else => {
                    if (c < 0x20) {
                        var buf: [6]u8 = undefined;
                        const esc = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
                        try list.appendSlice(allocator, esc);
                    } else {
                        try list.append(allocator, c);
                    }
                },
            }
        }
        try list.append(allocator, '"');
        return list.toOwnedSlice(allocator);
    }


    /// Log a message to a new file.
    /// On any failure, logs a warning to stderr and returns without panicking.
    /// tool_calls: optional list of tool call entries (name, arguments_json)
    pub fn logMessage(
        self: *Self,
        role: []const u8,
        content: []const u8,
        session_id: ?[]const u8,
        tool_calls: ?[]const ToolCallLog,
    ) void {
        if (!self.enabled) return;

        const allocator = self.allocator;
        const body_content = content;

        // Detect tool result messages and log them as "tool" role instead of "user"
        const is_tool_result = std.mem.indexOf(u8, content, "<tool_result") != null;
        const logged_role = if (is_tool_result) "tool" else role;

        // Compute current timestamp parts
        const now = std.time.nanoTimestamp();
        const epoch_secs = @as(u64, @intCast(@divTrunc(now, 1_000_000_000)));
        const ns = @mod(now, 1_000_000_000);
        const micros = @as(u32, @intCast(@divTrunc(ns, 1000)));

        const epoch = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
        const day = epoch.getEpochDay().calculateYearDay();
        const md = day.calculateMonthDay();

        const year = day.year;
        const month = @intFromEnum(md.month);
        const day_index = md.day_index + 1;

        const day_secs = epoch_secs % 86400;
        const hour = @as(u8, @intCast(day_secs / 3600));
        const minute = @as(u8, @intCast((day_secs % 3600) / 60));
        const second = @as(u8, @intCast(day_secs % 60));

        // Build path: messages_dir/YYYY-MM-DD/HHMMSS_ffffff.md
        const date_subdir = std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, month, day_index }) catch |err| {
            logWarning("failed to format date subdir: {s}", .{@errorName(err)});
            return;
        };
        defer allocator.free(date_subdir);

        const time_str = std.fmt.allocPrint(allocator, "{d:0>2}{d:0>2}{d:0>2}_{d:0>6}", .{ hour, minute, second, micros }) catch |err| {
            logWarning("failed to format time string: {s}", .{@errorName(err)});
            return;
        };
        defer allocator.free(time_str);

        const full_dir = std.fs.path.join(allocator, &.{ self.messages_dir, date_subdir }) catch |err| {
            logWarning("failed to build directory path: {s}", .{@errorName(err)});
            return;
        };
        defer allocator.free(full_dir);

        const path = std.fmt.allocPrint(allocator, "{s}/{s}.md", .{ full_dir, time_str }) catch |err| {
            logWarning("failed to build file path: {s}", .{@errorName(err)});
            return;
        };
        defer allocator.free(path);

        // Ensure directory exists
        self.ensureMessagesDir(path) catch |err| {
            logWarning("failed to create messages directory: {s}", .{@errorName(err)});
            return;
        };

        // Create file
        const file = std.fs.cwd().createFile(path, .{ .truncate = true, .read = false }) catch |err| {
            logWarning("failed to create message log file '{s}': {s}", .{ path, @errorName(err) });
            return;
        };
        defer file.close();

        // Escape frontmatter fields
        const escaped_role = escapeYamlString(allocator, logged_role) catch |err| {
            logWarning("failed to escape role for YAML: {s}", .{@errorName(err)});
            return;
        };
        defer allocator.free(escaped_role);

        const escaped_session = if (session_id) |sid|
            escapeYamlString(allocator, sid) catch |err| {
                logWarning("failed to escape session_id for YAML: {s}", .{@errorName(err)});
                return;
            }
        else
            null;
        defer if (escaped_session) |es| allocator.free(es);

        // Build ISO timestamp from current time
        const iso_timestamp = std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}Z", .{
            year, month, day_index, hour, minute, second, micros,
        }) catch |err| {
            logWarning("failed to format ISO timestamp: {s}", .{@errorName(err)});
            return;
        };
        defer allocator.free(iso_timestamp);

        // Start building frontmatter
        var frontmatter_buf = std.ArrayListUnmanaged(u8){};
        defer frontmatter_buf.deinit(allocator);

        // Write YAML frontmatter header
        frontmatter_buf.appendSlice(allocator, "---\n") catch {};
        // timestamp
        frontmatter_buf.appendSlice(allocator, "timestamp: ") catch {};
        frontmatter_buf.appendSlice(allocator, iso_timestamp) catch {};
        frontmatter_buf.appendSlice(allocator, "\n") catch {};
        // role
        frontmatter_buf.appendSlice(allocator, "role: ") catch {};
        frontmatter_buf.appendSlice(allocator, escaped_role) catch {};
        frontmatter_buf.appendSlice(allocator, "\n") catch {};
        // session_id
        frontmatter_buf.appendSlice(allocator, "session_id: ") catch {};
        if (escaped_session) |es| {
            frontmatter_buf.appendSlice(allocator, es) catch {};
        } else {
            frontmatter_buf.appendSlice(allocator, "null") catch {};
        }
        frontmatter_buf.appendSlice(allocator, "\n") catch {};

        // tool_calls (if present)
        if (tool_calls) |calls| {
            if (calls.len > 0) {
                frontmatter_buf.appendSlice(allocator, "tool_calls:\n") catch {};
                for (calls) |call| {
                    frontmatter_buf.appendSlice(allocator, "  - name: ") catch {};
                    const escaped_name = escapeYamlString(allocator, call.name) catch "";
                    defer allocator.free(escaped_name);
                    frontmatter_buf.appendSlice(allocator, escaped_name) catch {};
                    frontmatter_buf.appendSlice(allocator, "\n") catch {};

                    // Write arguments as a YAML block scalar (literal >) to preserve JSON structure
                    frontmatter_buf.appendSlice(allocator, "    arguments: |-\n") catch {};
                    // Indent each line of the JSON by 6 spaces
                    var lines = std.mem.splitScalar(u8, call.arguments_json, '\n');
                    while (lines.next()) |line| {
                        frontmatter_buf.appendSlice(allocator, "      ") catch {};
                        frontmatter_buf.appendSlice(allocator, line) catch {};
                        frontmatter_buf.appendSlice(allocator, "\n") catch {};
                    }
                }
            }
        }

        frontmatter_buf.appendSlice(allocator, "---\n") catch {};

        // Write frontmatter to file
        file.writeAll(frontmatter_buf.items) catch |err| {
            logWarning("failed to write frontmatter to message log: {s}", .{@errorName(err)});
            return;
        };

        // Write content body (as-is, ensure newline-terminated)
        if (body_content.len > 0) {
            file.writeAll(body_content) catch |err| {
                logWarning("failed to write content to message log: {s}", .{@errorName(err)});
                return;
            };
            if (body_content[body_content.len - 1] != '\n') {
                file.writeAll("\n") catch {};
            }
        }
    }

    /// Tool call data for frontmatter logging
    pub const ToolCallLog = struct {
        name: []const u8,
        arguments_json: []const u8,
    };

    fn logWarning(comptime fmt: []const u8, args: anytype) void {
        // Use stderr for warnings; not using std.log to avoid dependency on log level.
        std.debug.print("MessageLogger: " ++ fmt ++ "\n", args);
    }
};
