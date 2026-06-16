const std = @import("std");

pub fn termSucceeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

pub fn exitForTerm(term: std.process.Child.Term) noreturn {
    switch (term) {
        .exited => |code| std.process.exit(code),
        .signal => |signal| std.process.exit(@intCast(@min(@intFromEnum(signal) + 128, 255))),
        .stopped => |signal| std.process.exit(@intCast(@min(@intFromEnum(signal) + 128, 255))),
        .unknown => std.process.exit(1),
    }
}
