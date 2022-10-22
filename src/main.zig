const std = @import("std");

pub const RaylibApi = struct {
    defines: []const Define,
    structs: []const Struct,
    aliases: []const Alias,
    enums: []const Enum,
    callbacks: []const Callback,
    functions: []const Function,

    pub fn parse(
        allocator: std.mem.Allocator,
        reader: std.io.Reader(),
    ) (@TypeOf(reader).Error || std.mem.Allocator.Error || error{RaylibApiParseError})!RaylibApi {
        if (!try reader.isBytes("\nDefines found: ")) return error.RaylibApiParseError;

        const defines_found = try expectItemListBegin(reader, "Defines");
        const defines = try allocator.alloc(Define, @intCast(usize, defines_found));
        errdefer allocator.free(defines);
        if (!try reader.isBytes("\n\n")) return error.RaylibApiParseError;
        for (defines) |*define, i| {
            errdefer for (defines[0..i]) |prev| prev.free(allocator);
            try expectItemBegin(reader, "Define", "d:0<3", i + 1);
            try reader.skipUntilDelimiterOrEof('\n');

            try expectItemFieldName(reader, "Name");
            define.name = (try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 64)) orelse
                return error.RaylibApiParseError;
            errdefer allocator.free(define.name);

            try expectItemFieldName(reader, "Type");
            define.type = blk: {
                const type_str = (try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 256)) orelse
                    return error.RaylibApiParseError;
                defer allocator.free(type_str);
                break :blk Define.Type.parse(type_str) orelse
                    return error.RaylibApiParseError;
            };

            try expectItemFieldName(reader, "Value");
            define.value = (try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 4096)) orelse
                return error.RaylibApiParseError;
            errdefer allocator.free(define.value);
            
            try expectItemFieldName(reader, "Description");
            define.description = (try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 4096 * 4)) orelse
                return error.RaylibApiParseError;
            errdefer allocator.free(define.description);
        }

        return RaylibApi{
            .defines = defines,
        };
    }

    inline fn expectItemListBegin(
        reader: anytype,
        comptime prefix: []const u8,
    ) (@TypeOf(reader).Error || error{RaylibApiParseError})!?u64 {
        if (!try reader.isBytes("\n" ++ prefix ++ " found: ")) {
            return error.RaylibApiParseError;
        }
        var buf: [std.fmt.count("{d}", .{std.math.maxInt(u64)})]u8 = undefined;
        const num_str = (try reader.readUntilDelimiterOrEof(buf[0..], '\n')) orelse return error.RaylibApiParseError;

        const result = std.fmt.parseInt(u64, num_str, 0) catch |err| return switch (err) {
            error.Overflow,
            error.InvalidCharacter,
            => error.RaylibApiParseError,
        };
        if (!try reader.isBytes("\n\n")) return error.RaylibApiParseError;
        return result;
    }

    /// Returns the title of the item
    inline fn expectItemBegin(
        reader: anytype,
        comptime prefix: []const u8,
        comptime index_fmt: []const u8,
        index: u64,
    ) (@TypeOf(reader).Error || error{RaylibApiParseError})!void {
        std.debug.assert(index > 0);
        const fmt_str: []const u8 = prefix ++ " {" ++ index_fmt ++ "}: ";
        var buf: [std.fmt.count(fmt_str, .{std.math.maxInt(u64)})]u8 = undefined;
        const expected: []const u8 = std.fmt.bufPrint(buf[0..], fmt_str, .{index}) catch unreachable;
        if (!try reader.isBytes(expected)) {
            return error.RaylibApiParseError;
        }
    }

    inline fn expectItemFieldName(
        reader: std.io.Reader(),
        comptime name: []const u8,
    ) (@TypeOf(reader).Error || error{RaylibApiParseError})!void {
        if (!try reader.isBytes("  " ++ name ++ ": ")) {
            return error.RaylibApiParseError;
        }
    }

    pub fn free(self: RaylibApi, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }

    pub const Define = struct {
        name: []const u8,
        type: Type,
        value: []const u8,
        description: []const u8,

        pub fn free(define: Define, allocator: std.mem.Allocator) void {
            allocator.free(define.description);
            allocator.free(define.value);
            allocator.free(define.name);
        }

        pub const Type = enum {
            unknown,
            macro,
            guard,
            int,
            int_math,
            long,
            long_math,
            float,
            float_math,
            double,
            double_math,
            char,
            string,
            color,

            pub fn parse(str: []const u8) ?Type {
                const Uppercase = comptime Uppercase: {
                    const info: std.builtin.Type.Enum = @typeInfo(Type).Enum;
                    var fields = info.fields[0..info.fields.len].*;
                    for (fields) |*field| {
                        var buf: [field.name.len]u8 = undefined;
                        field.name = std.ascii.upperString(buf[0..], field.name);
                    }
                    break :Uppercase @Type(.{ .Enum = std.builtin.Type.Enum{
                        .layout = .Auto,
                        .tag_type = info.tag_type,
                        .fields = fields[0..],
                        .decls = &.{},
                        .is_exhaustive = true,
                    } });
                };
                const uppercase = std.meta.stringToEnum(Uppercase, str) orelse return null;
                return @intToEnum(Type, @enumToInt(uppercase));
            }
        };
    };
    pub const Struct = struct {
        name: []const u8,
        description: []const u8,
        fields: []const Field,

        pub const Field = struct {
            type: []const u8,
            name: []const u8,
            description: []const u8,
        };

        pub fn free(strct: Struct, allocator: std.mem.Allocator) void {
            var bkwd_it = backwardsIterator(strct.fields);
            while (bkwd_it.next()) |field| {
                allocator.free(field.description);
                allocator.free(field.name);
                allocator.free(field.type);
            }
            allocator.free(strct.fields);
            allocator.free(strct.description);
            allocator.free(strct.name);
        }
    };
    pub const Alias = struct {
        type: []const u8,
        name: []const u8,
        description: []const u8,

        pub fn free(alias: Alias, allocator: std.mem.Allocator) void {
            allocator.free(alias.description);
            allocator.free(alias.name);
            allocator.free(alias.type);
        }
    };
    pub const Enum = struct {
        name: []const u8,
        description: []const u8,
        values: []const Value,

        pub const Value = struct {
            name: []const u8,
            value: []const u8,
            description: []const u8,
        };

        pub fn free(enm: Enum, allocator: std.mem.Allocator) void {
            var bkwd_it = backwardsIterator(enm.values);
            while (bkwd_it.next()) |value| {
                allocator.free(value.description);
                allocator.free(value.value);
                allocator.free(value.name);
            }
            allocator.free(enm.values);
            allocator.free(enm.description);
            allocator.free(enm.name);
        }
    };
    pub const Callback = struct {
        name: []const u8,
        return_type: []const u8,
        description: []const u8,
        params: []const Param,

        pub const Param = struct {
            type: []const u8,
            name: []const u8,
        };

        pub fn free(callback: Callback, allocator: std.mem.Allocator) void {
            var bkwd_it = backwardsIterator(callback.params);
            while (bkwd_it.next()) |param| {
                allocator.free(param.name);
                allocator.free(param.type);
            }
            allocator.free(callback.params);
            allocator.free(callback.description);
            allocator.free(callback.return_type);
            allocator.free(callback.name);
        }
    };
    pub const Function = struct {
        name: []const u8,
        return_type: []const u8,
        description: []const u8,
        params: []const Param,

        pub const Param = struct {
            type: []const u8,
            name: []const u8,
        };

        pub fn free(function: Function, allocator: std.mem.Allocator) void {
            var bkwd_it = backwardsIterator(function.params);
            while (bkwd_it.next()) |param| {
                allocator.free(param.name);
                allocator.free(param.type);
            }
            allocator.free(function.params);
            allocator.free(function.description);
            allocator.free(function.return_type);
            allocator.free(function.name);
        }
    };
};

fn BackwardsIterator(comptime T: type, comptime is_const: bool) type {
    return struct {
        const Self = @This();
        slice: if (is_const) []const T else []T,
        index: usize,

        pub fn init(slice: []const T) Self {
            return Self{
                .slice = slice,
                .index = slice.len,
            };
        }

        pub fn reset(self: *Self) void {
            self.* = Self.init(self.slice);
        }

        pub inline fn next(self: *Self) ?T {
            if (self.index == 0) return null;
            self.index -= 1;
            return self.slice[self.index];
        }
    };
}
fn backwardsIterator(slice: anytype) BackwardsIterator(std.mem.Span(@TypeOf(slice)), @typeInfo(@TypeOf(slice)).Pointer.is_const) {
    const Slice = std.mem.Span(@TypeOf(slice));
    return BackwardsIterator(Slice, @typeInfo(Slice).Pointer.is_const).init(slice);
}
