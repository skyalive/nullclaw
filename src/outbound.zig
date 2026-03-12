const std = @import("std");

pub const AttachmentKind = enum {
    image,
    document,
    video,
    audio,
    voice,
};

pub const Attachment = struct {
    kind: AttachmentKind,
    target: []const u8,
    caption: ?[]const u8 = null,
};

pub const Choice = struct {
    id: []const u8,
    label: []const u8,
    submit_text: []const u8,

    pub fn deinit(self: *const Choice, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.label);
        allocator.free(self.submit_text);
    }
};

pub const Payload = struct {
    text: []const u8 = "",
    attachments: []const Attachment = &.{},
    choices: []const Choice = &.{},
};
