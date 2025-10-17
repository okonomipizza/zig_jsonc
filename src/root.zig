//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const JsoncParser = @import("parse.zig").JsoncParser;
pub const JsoncParseError = @import("parse.zig").ParseError;
