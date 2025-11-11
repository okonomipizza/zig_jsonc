const std = @import("std");

/// Errors that occurs during parsing
pub const ParseError = error{
    // Invalid characeter and tokens
    InvalidToken,
    InvalidNumber,
    UnexpectedCharacter,
    UnexpectedToken,

    // Syntax errors
    UnterminatedString,
    UnterminatedArray,
    UnterminatedObject,
    UnclosedComment,

    IncompleteKeyValuePair,

    MissingComma,

    /// Returned when the parser is given an empty JSON string
    EmptyJsonString,

    /// Returned when the array or object has empty content
    EmptyElemnt,

    IndexOutOfBounds,

    // Memory related errors
    OutOfMemory,
};

pub const ValueRange = struct { start: usize, end: usize };
pub const PositionMap = std.AutoHashMap(usize, ValueRange);
pub const CommentRanges = std.ArrayList(ValueRange);

pub const ParseResult = union(enum) {
    ok: std.json.Value,
    err: ParseErrorInfo,

    pub const ParseErrorInfo = struct {
        kind: ParseError,
        row: usize,
        col: usize,
        message: []const u8,
    };
};

pub const JsoncParser = struct {
    /// Original Json with Comments text
    jsonc_str: []const u8,
    /// Current offset
    idx: usize,
    /// Current row number and col number
    /// These position will be used when parser encounted a syntax error.
    row: usize,
    col: usize,

    last_error_row: usize = 0,
    last_error_col: usize = 0,
    last_error_message: []const u8 = "",

    arena: std.heap.ArenaAllocator,

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator, jsonc_str: []const u8) !Self {
        return .{
            .jsonc_str = jsonc_str,
            .idx = 0,
            .row = 0,
            .col = 0,
            .arena = std.heap.ArenaAllocator.init(alloc),
        };
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    fn allocator(self: *Self) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn parse(self: *Self) ParseResult {
        if (self.jsonc_str.len == 0) {
            return ParseResult{ .err = .{
                .kind = ParseError.EmptyJsonString,
                .row = 0,
                .col = 0,
                .message = "Empty JSON string",
            } };
        }

        const result = self.parseRecursive() catch |err| {
            return ParseResult{ .err = .{
                .kind = err,
                .row = self.last_error_row,
                .col = self.last_error_col,
                .message = self.last_error_message,
            } };
        };

        return ParseResult{ .ok = result };
    }

    fn parseRecursive(self: *Self) ParseError!std.json.Value {
        const row = self.row;
        const col = self.col;

        if (self.jsonc_str.len == 0) return ParseError.EmptyJsonString;
        while (self.idx < self.jsonc_str.len) : (try self.advanceN(1)) {
            const char = self.getChar(self.idx) orelse continue;
            if (isWhiteSpace(char)) continue;
            switch (char) {
                'n' => return self.parseLiteral(.null),
                't' => return self.parseLiteral(.true),
                'f' => return self.parseLiteral(.false),
                '"' => return self.parseString(),
                '[' => return self.parseArray(),
                '{' => return self.parseObject(),
                '0'...'9', '-', 'e', '.' => return self.parseNumber(),
                else => return self.recordError(
                    ParseError.UnexpectedCharacter,
                    row,
                    col,
                    "Unexpected character",
                ),
            }
        }
        return self.recordError(ParseError.EmptyJsonString, row, col, "No valid JSON value found");
    }

    const LiteralType = enum {
        null,
        true,
        false,

        fn toString(self: LiteralType) []const u8 {
            return switch (self) {
                .null => "null",
                .true => "true",
                .false => "false",
            };
        }
    };

    /// Parse json value 'null', 'true' and 'false'.
    fn parseLiteral(self: *Self, literal_type: LiteralType) ParseError!std.json.Value {
        const row = self.row;
        const col = self.col;

        const expected = literal_type.toString();

        // Too short for the expected token.
        if (self.idx + expected.len > self.jsonc_str.len) {
            return self.recordError(ParseError.InvalidToken, row, col, "Invalid token");
        }

        const maybe_literal = self.jsonc_str[self.idx .. self.idx + expected.len];
        if (!std.mem.eql(u8, maybe_literal, expected)) {
            return self.recordError(ParseError.InvalidToken, row, col, "Invalid token");
        }

        try self.advanceN(expected.len - 1);

        return switch (literal_type) {
            .null => std.json.Value{ .null = {} },
            .true => std.json.Value{ .bool = true },
            .false => std.json.Value{ .bool = false },
        };
    }

    fn parseString(self: *Self) ParseError!std.json.Value {
        const row = self.row;
        const col = self.col;

        const alloc = self.allocator();
        var list = try std.ArrayList(u8).initCapacity(alloc, 64);

        // Skip the opening quote
        try self.advanceN(1);

        while (true) : (self.advanceN(1) catch {
            return self.recordError(ParseError.UnterminatedString, row, col, "Unterminated string");
        }) {
            const char = self.getChar(self.idx) orelse {
                break;
            };
            // JSON strings cannot contain unescaped newlines
            if (char == '\n' or char == '\r') {
                return self.recordError(ParseError.UnterminatedString, row, self.col - 1, "Unterminated string");
            }

            if (char == '"') {
                return std.json.Value{ .string = list.items };
            } else if (char == '\\') {
                // Handle escape sequences
                try self.advanceN(1);
                const next_char = self.getChar(self.idx) orelse {
                    return self.recordError(ParseError.UnterminatedString, row, col, "Unterminated string");
                };
                switch (next_char) {
                    '"', '\\', '/' => try list.append(alloc, next_char),
                    'n' => try list.append(alloc, '\n'),
                    't' => try list.append(alloc, '\t'),
                    'r' => try list.append(alloc, '\r'),
                    else => {
                        try list.append(alloc, '\\');
                        try list.append(alloc, next_char);
                    },
                }
            } else {
                try list.append(alloc, char);
            }
        }

        return self.recordError(ParseError.UnterminatedString, row, col, "Unterminated string");
    }

    fn parseNumber(self: *Self) ParseError!std.json.Value {
        const col = self.col;
        const row = self.row;

        const alloc = self.allocator();
        var bytes = try std.ArrayList(u8).initCapacity(alloc, 64);
        defer bytes.deinit(alloc);

        var has_dot = false;
        var has_e = false;

        while (self.idx < self.jsonc_str.len) : (self.advanceN(1) catch break) {
            switch (self.getChar(self.idx) orelse {
                break;
            }) {
                '0'...'9' => |digit| {
                    try bytes.append(alloc, digit);
                },
                '-' => |minus| {
                    if (bytes.items.len == 0 or
                        (bytes.items.len > 0 and (bytes.items[bytes.items.len - 1] == 'e' or bytes.items[bytes.items.len - 1] == 'E')))
                    {
                        try bytes.append(alloc, minus);
                    } else {
                        break;
                    }
                },
                '.' => |dot| {
                    if (!has_dot and !has_e) {
                        has_dot = true;
                        try bytes.append(alloc, dot);
                    } else {
                        break;
                    }
                },
                'e', 'E' => |e| {
                    if (!has_e and bytes.items.len > 0) {
                        has_e = true;
                        try bytes.append(alloc, e);
                    } else {
                        break;
                    }
                },
                '+' => |plus| {
                    // Only allow plus after 'e'/'E'
                    if (bytes.items.len > 0 and (bytes.items[bytes.items.len - 1] == 'e' or bytes.items[bytes.items.len - 1] == 'E')) {
                        try bytes.append(alloc, plus);
                    } else {
                        break;
                    }
                },
                else => {
                    break;
                },
            }
        }

        if (bytes.items.len == 0) return self.recordError(ParseError.InvalidNumber, row, col, "Invalid number");

        if (has_dot or has_e) {
            const float_val = std.fmt.parseFloat(f64, bytes.items) catch {
                return self.recordError(ParseError.InvalidNumber, row, col, "Invalid number");
            };
            return std.json.Value{ .float = float_val };
        } else {
            const int_val = std.fmt.parseInt(i64, bytes.items, 10) catch {
                return self.recordError(ParseError.InvalidNumber, row, col, "Invalid number");
            };
            return std.json.Value{ .integer = int_val };
        }
    }

    fn parseArray(self: *Self) ParseError!std.json.Value {
        const row = self.row;
        const col = self.col;
        const alloc = self.allocator();
        var array = std.json.Array.init(alloc);
        errdefer array.deinit();

        try self.advanceN(1); // Skip opening bracket

        var comma = true;

        while (self.idx < self.jsonc_str.len) : (self.advanceN(1) catch {
            return self.recordError(ParseError.UnterminatedArray, row, col, "Array is not closed");
        }) {
            const char = self.getChar(self.idx) orelse {
                break;
            };
            if (char == ']') {
                // Found closing quote
                return std.json.Value{ .array = array };
            } else if (isWhiteSpace(char) or char == '/') {
                try self.skipWhiteAndComments();
            } else if (char == ',') {
                // No element between ',' is not allowed.
                // ex) [a, , c]
                if (comma) return self.recordError(ParseError.EmptyElemnt, self.row, self.col, "Empty content of array is not allowed");
                comma = true;
                try self.skipWhiteAndComments();
            } else {
                if (comma) comma = false;
                const parsed = self.parseRecursive() catch {
                    return self.recordError(ParseError.UnterminatedArray, row, col, "Array is not closed");
                };
                try array.append(parsed);
                if (parsed == .string) {
                    continue;
                } else {
                    try self.retreat();
                }
            }
        }

        return self.recordError(ParseError.UnterminatedArray, row, col, "Array is not closed");
    }

    fn parseObject(self: *Self) ParseError!std.json.Value {
        const alloc = self.allocator();
        var object = std.json.ObjectMap.init(alloc);
        errdefer object.deinit();

        try self.advanceN(1); // Skip opening curley bracket.

        while (true) {
            try self.skipWhiteAndComments();
            try self.advanceN(1); // maybe '"'

            // Check for empty elements in object after key-value pair
            // ex) { "key": "value", , "key2": "value2" }
            if (self.getChar(self.idx) == ',') {
                return self.recordError(ParseError.EmptyElemnt, self.row, self.col, "Empty content of object is not allowed");
            }

            if (self.getChar(self.idx) != '"') {
                return self.recordError(ParseError.IncompleteKeyValuePair, self.row, self.col, "Invalid key string");
            }

            const key = try self.parseString();

            try self.advanceN(1); // Skip last '"' of the key string

            if (self.getChar(self.idx)) |char| {
                if (char != ':') {
                    try self.skipWhiteAndComments();
                    try self.advanceN(1);
                }
            }
            if (self.getChar(self.idx) != ':') return self.recordError(ParseError.IncompleteKeyValuePair, self.row, self.col, "\":\" is missing after key of object");

            try self.skipWhiteAndComments();
            try self.advanceN(1);

            const value = try self.parseRecursive();

            try object.put(key.string, value);

            switch (value) {
                .string => {
                    try self.advanceN(1);
                },
                .object, .array => {},
                else => {},
            }

            if (self.getChar(self.idx)) |char| {
                if (char != ',') {
                    try self.skipWhiteAndComments();
                    try self.advanceN(1);
                }
            }

            if (self.getChar(self.idx) == ',') {
                try self.skipWhiteAndComments();
                continue;
            }

            if (self.getChar(self.idx) == '}') break;

            return self.recordError(ParseError.MissingComma, self.row, self.col, "Missing \",\" after value");
        }

        return std.json.Value{ .object = object };
    }

    // Stop at next to last space
    fn skipWhiteAndComments(self: *Self) ParseError!void {
        while (true) : (self.advanceN(1) catch break) {
            const char = self.peekNextChar() orelse break;
            if (isWhiteSpace(char)) {
                continue;
            } else if (char == '/') {
                try self.advanceN(1);
                try self.advanceToEndOfComments();
            } else {
                return;
            }
        }
    }

    fn advanceToEndOfComments(self: *Self) ParseError!void {
        const isSingleLineComment = blk: {
            const next_char = self.peekNextChar();
            if (next_char) |nc| {
                if (nc == '/') {
                    self.advanceN(2) catch return;
                    break :blk true;
                } else if (nc == '*') {
                    self.advanceN(2) catch return;
                    break :blk false;
                } else {
                    return self.recordError(ParseError.InvalidToken, self.row, self.col, "Invalid Token for Comment open");
                }
            }
            return;
        };

        while (true) : (self.advanceN(1) catch |err| {
            if (err == ParseError.IndexOutOfBounds and !isSingleLineComment) {
                return self.recordError(ParseError.UnclosedComment, self.row, self.col, "Comments should be closed with '*/'");
            } else {
                break;
            }
        }) {
            switch (isSingleLineComment) {
                true => {
                    const next_char = self.peekNextChar() orelse break;
                    if (next_char == '\n') break;
                },
                false => {
                    const char = self.getChar(self.idx) orelse break;
                    if (char == '*') {
                        const next = self.peekNextChar() orelse continue; // continue will occur err
                        if (next == '/') {
                            try self.advanceN(1);
                            break;
                        }
                    }
                },
            }
        }
    }

    /// Advance current offset to next.
    /// Advance JsonParser.idx by n characters.
    /// Additionally, update JsonParser.row and JsonParser.col
    /// in tandem with this change.
    fn advanceN(self: *Self, n: usize) ParseError!void {
        const new_idx = self.idx + n;
        if (new_idx >= self.jsonc_str.len) {
            return self.recordError(ParseError.IndexOutOfBounds, self.row, self.col, "An unexpected boundary crossing occurred during parsing");
        }
        self.idx = new_idx;
        // TODO Add code to update self.row and self.col
        self.updatePosition();
    }

    fn retreat(self: *Self) ParseError!void {
        if (self.idx == 0) {
            return self.recordError(ParseError.IndexOutOfBounds, self.row, self.col, "An unexpected boundary crossing occurred during parsing");
        }
        self.idx -= 1;
        self.updatePositionBackward();
    }

    fn updatePosition(self: *Self) void {
        if (self.idx > 0 and self.jsonc_str[self.idx - 1] == '\n') {
            self.row += 1;
            self.col = 0;
        } else {
            self.col += 1;
        }
    }

    fn updatePositionBackward(self: *Self) void {
        const current_char = self.jsonc_str[self.idx];
        if (current_char == '\n') {
            self.row -= 1;
            self.col = 0;
            var i = self.idx;
            while (i > 0) {
                i -= 1;
                if (self.jsonc_str[i] == '\n') break;
                self.col += 1;
            }
        } else {
            self.col -= 1;
        }
    }

    /// Get char at designated offset in original jsonc string.
    fn getChar(self: Self, position: usize) ?u8 {
        if (position >= self.jsonc_str.len) return null;
        return self.jsonc_str[position];
    }

    fn peekNextChar(self: Self) ?u8 {
        const next_idx = self.idx + 1;
        if (next_idx < self.jsonc_str.len) {
            return self.jsonc_str[next_idx];
        }
        return null;
    }

    fn isWhiteSpace(c: u8) bool {
        return switch (c) {
            ' ', '\n', '\t', '\r' => true,
            else => false,
        };
    }

    fn recordError(self: *Self, err: ParseError, row: usize, col: usize, message: []const u8) ParseError {
        self.last_error_row = row + 1;
        self.last_error_col = col + 1;
        self.last_error_message = message;
        return err;
    }
};

const testing = std.testing;

test "Parse null" {
    const input = "null";
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const result = parser.parse();
    try testing.expect(result == .ok);

    try testing.expect(result.ok == .null);
}

test "Parse null failed" {
    const input = "nul invalid";
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const result = parser.parse();
    try testing.expect(result == .err);

    try testing.expectEqual(ParseError.InvalidToken, result.err.kind);
    try testing.expectEqual(1, result.err.row);
    try testing.expectEqual(1, result.err.col);
}

test "Parse true" {
    const input = "true";
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const result = parser.parse();
    try testing.expect(result == .ok);

    try testing.expect(result.ok == .bool);
    try testing.expect(result.ok.bool == true);
}

test "Parse false" {
    const input = "false";
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const result = parser.parse();
    try testing.expect(result == .ok);

    try testing.expect(result.ok == .bool);
    try testing.expect(result.ok.bool == false);
}

test "Parse string" {
    const input = "\"Hello world\"";
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const result = parser.parse();
    try testing.expect(result == .ok);

    try testing.expect(result.ok == .string);
    try testing.expectEqualStrings("Hello world", result.ok.string);
}

test "Parse string failed" {
    const input = "\"Hello world";
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const result = parser.parse();
    try testing.expect(result == .err);

    try testing.expectEqual(ParseError.UnterminatedString, result.err.kind);
    try testing.expectEqual(1, result.err.row);
    try testing.expectEqual(1, result.err.col);
}

test "Parse integer" {
    const input = "1234567890";
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const result = parser.parse();
    try testing.expect(result == .ok);

    try testing.expect(result.ok == .integer);
    try testing.expectEqual(1234567890, result.ok.integer);
}

test "Parse negative integer" {
    const input = "-1234567890";
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const result = parser.parse();
    try testing.expect(result == .ok);

    try testing.expect(result.ok == .integer);
    try testing.expectEqual(-1234567890, result.ok.integer);
}

test "Parse fraction" {
    const input = "123.456";
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const result = parser.parse();
    try testing.expect(result == .ok);

    try testing.expect(result.ok == .float);
    try testing.expectEqual(123.456, result.ok.float);
}

test "Parse exponential plus" {
    const input = "1.23e+4";
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const result = parser.parse();
    try testing.expect(result == .ok);

    try testing.expect(result.ok == .float);
    try testing.expectEqual(1.23e+4, result.ok.float);
}

test "Parse exponential negative" {
    const input = "1.23e-4";
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const result = parser.parse();
    try testing.expect(result == .ok);

    try testing.expect(result.ok == .float);
    try testing.expectEqual(1.23e-4, result.ok.float);
}

test "Parse array" {
    const input = "[1, 2, 3]";
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const result = parser.parse();
    try testing.expect(result == .ok);

    try testing.expect(result.ok == .array);

    try testing.expectEqual(3, result.ok.array.items.len);
    const first_elemet = result.ok.array.items[0].integer;
    const second_element = result.ok.array.items[1].integer;
    const third_elemet = result.ok.array.items[2].integer;

    try testing.expectEqual(1, first_elemet);
    try testing.expectEqual(2, second_element);
    try testing.expectEqual(3, third_elemet);
}

test "Parse array has string" {
    const input = "[\"hello\", \"world\"]";
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const result = parser.parse();
    try testing.expect(result == .ok);
    try testing.expect(result.ok == .array);

    try testing.expectEqual(2, result.ok.array.items.len);
    const first_elemet = result.ok.array.items[0].string;
    const second_element = result.ok.array.items[1].string;

    try testing.expectEqualStrings("hello", first_elemet);
    try testing.expectEqualStrings("world", second_element);
}

test "Parse array has 0 length string" {
    const input = "[\"hello\", \"\"]";
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const result = parser.parse();
    try testing.expect(result == .ok);
    try testing.expect(result.ok == .array);

    try testing.expectEqual(2, result.ok.array.items.len);
    const first_elemet = result.ok.array.items[0].string;
    const second_element = result.ok.array.items[1].string;

    try testing.expectEqualStrings("hello", first_elemet);
    try testing.expectEqualStrings("", second_element);
}

test "Parse array with empty element" {
    const input = "[1, , 3]";
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const result = parser.parse();
    try testing.expect(result == .err);

    try testing.expectEqual(ParseError.EmptyElemnt, result.err.kind);
    try testing.expectEqual(1, result.err.row);
    try testing.expectEqual(5, result.err.col);
}

test "Parse object" {
    const input =
        \\{
        \\  "lang": "zig",
        \\  "version" : 0.14
        \\}
    ;
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const result = parser.parse();
    try testing.expect(result == .ok);
    try testing.expect(result.ok == .object);

    try testing.expectEqualStrings("zig", result.ok.object.get("lang").?.string);
    try testing.expectEqual(0.14, result.ok.object.get("version").?.float);
}

test "Parse string with escape sequences" {
    const input =
        \\{
        \\  "message": "Hello\nWorld",
        \\  "path": "C:\\Users\\file.txt",
        \\  "quote": "He said \"Hello\"",
        \\  "tab": "Name:\tValue",
        \\  "slash": "https:\/\/example.com"
        \\}
    ;
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const result = parser.parse();
    try testing.expect(result == .ok);
    try testing.expect(result.ok == .object);

    // Test newline escape
    try testing.expectEqualStrings("Hello\nWorld", result.ok.object.get("message").?.string);

    // Test backslash escape
    try testing.expectEqualStrings("C:\\Users\\file.txt", result.ok.object.get("path").?.string);

    // Test quote escape
    try testing.expectEqualStrings("He said \"Hello\"", result.ok.object.get("quote").?.string);

    // Test tab escape
    try testing.expectEqualStrings("Name:\tValue", result.ok.object.get("tab").?.string);

    // Test forward slash escape
    try testing.expectEqualStrings("https://example.com", result.ok.object.get("slash").?.string);
}

test "Parse object with unterminated string value" {
    const input =
        \\{
        \\  "lang": "zig,
        \\  "version" : 0.14
        \\}
    ;
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const result = parser.parse();
    try testing.expect(result == .err);

    try testing.expectEqual(ParseError.UnterminatedString, result.err.kind);
    try testing.expectEqual(2, result.err.row);
    try testing.expectEqual(15, result.err.col);
}

test "Parse object with unopened string value" {
    const input =
        \\{
        \\  "lang": zig",
        \\  "version" : 0.14
        \\}
    ;
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const result = parser.parse();
    try testing.expect(result == .err);

    try testing.expectEqual(ParseError.UnexpectedCharacter, result.err.kind);
    try testing.expectEqual(2, result.err.row);
    try testing.expectEqual(11, result.err.col);
}

test "Parse object with empty line at first" {
    const input =
        \\
        \\{
        \\  "lang": "zig",
        \\  "version" : 0.14
        \\}
    ;
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const result = parser.parse();
    try testing.expect(result == .ok);
    try testing.expect(result.ok == .object);

    try testing.expectEqualStrings("zig", result.ok.object.get("lang").?.string);
    try testing.expectEqual(0.14, result.ok.object.get("version").?.float);
}

test "Parse object missing commma between value and next key" {
    const input =
        \\{
        \\  "lang": "zig"
        \\  "version" : 0.14
        \\}
    ;
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const result = parser.parse();
    try testing.expect(result == .err);

    try testing.expectEqual(ParseError.MissingComma, result.err.kind);
    try testing.expectEqual(3, result.err.row);
    try testing.expectEqual(3, result.err.col);
}

test "Parse object has string array" {
    const input =
        \\{
        \\  "lang": "English",
        \\  "greeting": [  "Good morning" , "Hello", "Good evening"]
        \\}
    ;
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const result = parser.parse();
    try testing.expect(result == .ok);
    try testing.expect(result.ok == .object);

    try testing.expectEqualStrings("English", result.ok.object.get("lang").?.string);
    try testing.expectEqual(3, result.ok.object.get("greeting").?.array.items.len);
    try testing.expectEqualStrings("Good morning", result.ok.object.get("greeting").?.array.items[0].string);
    try testing.expectEqualStrings("Hello", result.ok.object.get("greeting").?.array.items[1].string);
    try testing.expectEqualStrings("Good evening", result.ok.object.get("greeting").?.array.items[2].string);
}

test "Parse object has unterminated array" {
    const input =
        \\{
        \\  "lang": "English",
        \\  "greeting": [  "Good morning" , "Hello", "Good evening"
        \\}
    ;
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const result = parser.parse();
    try testing.expect(result == .err);

    try testing.expectEqual(ParseError.UnterminatedArray, result.err.kind);
    try testing.expectEqual(3, result.err.row);
    try testing.expectEqual(15, result.err.col);
}

test "Parse object with comment" {
    const input =
        \\ {
        \\     "lang": "zig", // general-purpose programming language
        \\     "version": 0.14
        \\ }
    ;
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const result = parser.parse();
    try testing.expect(result == .ok);
    try testing.expect(result.ok == .object);

    try testing.expectEqualStrings("zig", result.ok.object.get("lang").?.string);
    try testing.expectEqual(0.14, result.ok.object.get("version").?.float);
}

test "Parse object with multi-line comment" {
    const input = "{\n" ++
        "  /*\n" ++
        "  multi-line\n" ++
        "   comments\n" ++
        "   */\n" ++
        "  \"lang\": \"zig\",\n" ++
        "  \"version\" : 0.14\n" ++
        "}";
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const result = parser.parse();
    try testing.expect(result == .ok);
    try testing.expect(result.ok == .object);

    try testing.expectEqualStrings("zig", result.ok.object.get("lang").?.string);
    try testing.expectEqual(0.14, result.ok.object.get("version").?.float);
}

test "Parse nested object" {
    const input =
        \\{
        \\    "music": {
        \\        "theme": {
        \\            "color": "#8a2be2"
        \\        }
        \\    },
        \\    "messages": [
        \\        "message1",
        \\        "message2",
        \\        "message3"
        \\    ]
        \\}
    ;

    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const result = parser.parse();
    try testing.expect(result == .ok);
    try testing.expect(result.ok == .object);

    const music = result.ok.object.get("music").?;
    try testing.expect(music == .object);

    const theme = music.object.get("theme").?;
    try testing.expect(theme == .object);

    const color = theme.object.get("color").?;
    try testing.expectEqualStrings("#8a2be2", color.string);

    const messages = result.ok.object.get("messages").?;
    try testing.expect(messages == .array);

    try testing.expectEqual(3, messages.array.items.len);

    const first_msg = messages.array.items[0];
    const second_msg = messages.array.items[1];
    const third_msg = messages.array.items[2];

    try testing.expectEqualStrings("message1", first_msg.string);
    try testing.expectEqualStrings("message2", second_msg.string);
    try testing.expectEqualStrings("message3", third_msg.string);
}
