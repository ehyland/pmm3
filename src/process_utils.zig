const std = @import("std");

pub fn termSucceeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

pub fn exitForTerm(term: std.process.Child.Term) noreturn {
    switch (term) {
        .Exited => |code| std.process.exit(code),
        .Signal => |signal| std.process.exit(@intCast(@min(signal + 128, 255))),
        .Stopped => |signal| std.process.exit(@intCast(@min(signal + 128, 255))),
        .Unknown => |_| std.process.exit(1),
    }
}
