local runtime = {}

do -- SECTION function_types
-- An indirect call compares the WebAssembly type of the function it found against the
-- type the call site expects, so every function a module defines registers its key here.
-- The table is weak keyed so an unreachable function value is still collected, and a host
-- function simply has no entry, which leaves it unchecked.
local rt_function_types = setmetatable({}, { __mode = "k" })
	runtime.rt_function_types = rt_function_types
end

do -- SECTION function_type
	local rt_function_types = runtime.rt_function_types
local function rt_function_type(source, key)
	rt_function_types[source] = key

	return source
end
	runtime.rt_function_type = rt_function_type
end

do -- SECTION bit
local bit = require("bit")
	runtime.bit = bit
end

do -- SECTION bit_and
	local bit = runtime.bit
local bit_and = bit.band
	runtime.bit_and = bit_and
end

do -- SECTION bit_lshift
	local bit = runtime.bit
local bit_lshift = bit.lshift
	runtime.bit_lshift = bit_lshift
end

do -- SECTION bit_or
	local bit = runtime.bit
local bit_or = bit.bor
	runtime.bit_or = bit_or
end

do -- SECTION bit_rshift
	local bit = runtime.bit
local bit_rshift = bit.rshift
	runtime.bit_rshift = bit_rshift
end

do -- SECTION bit_xor
	local bit = runtime.bit
local bit_xor = bit.bxor
	runtime.bit_xor = bit_xor
end

do -- SECTION buffer_meta
	local bit_and, bit_lshift, bit_or, bit_rshift, bit_xor = runtime.bit_and, runtime.bit_lshift, runtime.bit_or, runtime.bit_rshift, runtime.bit_xor
-- Exposes the packed words as a one based byte array. Host code outside the
-- generated module reads and writes linear memory through this view, so the
-- indices it takes are byte addresses plus one.
local buffer_meta = {
	__index = function(t, k)
		if type(k) ~= "number" or k < 1 or k > t.__n then
			return nil
		end

		local address = k - 1

		return bit_and(bit_rshift(t.__w[bit_rshift(address, 2) + 1], bit_lshift(bit_and(address, 3), 3)), 255)
	end,
	__newindex = function(t, k, v)
		if type(k) ~= "number" or k < 1 or k > t.__n then
			return
		end

		local address = k - 1
		local words = t.__w
		local index = bit_rshift(address, 2) + 1
		local shift = bit_lshift(bit_and(address, 3), 3)

		words[index] =
			bit_or(bit_and(words[index], bit_xor(bit_lshift(255, shift), -1)), bit_lshift(bit_and(v, 255), shift))
	end,
	__len = function(t)
		return t.__n
	end
}
	runtime.buffer_meta = buffer_meta
end

do -- SECTION buffer_new_table
-- Allocates a table with room for `size` array slots.
--
-- `table.new` is a `LuaJIT` extension, so it is loaded through `pcall`; a host
-- without it still works, and only pays for growing the array part instead.
local buffer_new_table
do
	local loaded, allocator = pcall(require, "table.new")

	if loaded and type(allocator) == "function" then
		buffer_new_table = allocator
	else
		buffer_new_table = function()
			return {}
		end
	end
end
	runtime.buffer_new_table = buffer_new_table
end

do -- SECTION math_floor
local math_floor = math.floor
	runtime.math_floor = math_floor
end

do -- SECTION buffer_create
	local buffer_meta, buffer_new_table, math_floor = runtime.buffer_meta, runtime.buffer_new_table, runtime.math_floor
local function buffer_create(size)
	local count = math_floor(size / 4) + 2
	local words = buffer_new_table(count, 0)

	for index = 1, count do
		words[index] = 0
	end

	return setmetatable({ __n = size, __w = words }, buffer_meta)
end
	runtime.buffer_create = buffer_create
end

do -- SECTION buffer_trap
local function buffer_trap()
	error("out of bounds memory access", 2)
end
	runtime.buffer_trap = buffer_trap
end

do -- SECTION buffer_writestring
	local bit_and, bit_lshift, bit_or, bit_rshift, bit_xor, buffer_trap = runtime.bit_and, runtime.bit_lshift, runtime.bit_or, runtime.bit_rshift, runtime.bit_xor, runtime.buffer_trap
-- Writes a data segment. The middle of the segment lands one whole word at a
-- time, which is what makes module start-up cheap for large segments.
local function buffer_writestring(buf, offset, str)
	local size = #str

	if offset < 0 or offset + size > buf.__n then
		buffer_trap()
	end

	if size == 0 then
		return
	end

	local string_byte = string.byte
	local words = buf.__w
	local head = bit_and(-offset, 3)

	if head > size then
		head = size
	end

	for k = 1, head do
		local address = offset + k - 1
		local slot = bit_rshift(address, 2) + 1
		local shift = bit_lshift(bit_and(address, 3), 3)

		words[slot] =
			bit_or(bit_and(words[slot], bit_xor(bit_lshift(255, shift), -1)), bit_lshift(string_byte(str, k), shift))
	end

	local count = bit_rshift(size - head, 2)
	local base = bit_rshift(offset + head, 2)

	for k = 1, count do
		local position = head + k * 4 - 3
		local b1, b2, b3, b4 = string_byte(str, position, position + 3)

		words[base + k] = bit_or(b1, bit_lshift(b2, 8), bit_lshift(b3, 16), bit_lshift(b4, 24))
	end

	for k = head + count * 4 + 1, size do
		local address = offset + k - 1
		local slot = bit_rshift(address, 2) + 1
		local shift = bit_lshift(bit_and(address, 3), 3)

		words[slot] =
			bit_or(bit_and(words[slot], bit_xor(bit_lshift(255, shift), -1)), bit_lshift(string_byte(str, k), shift))
	end
end
	runtime.buffer_writestring = buffer_writestring
end

do -- SECTION memory_new
	local buffer_create, buffer_writestring = runtime.buffer_create, runtime.buffer_writestring
local function rt_memory_new(initializer, minimum, maximum)
	local data = buffer_create(minimum)

	for offset, content in pairs(initializer) do
		buffer_writestring(data, offset, content)
	end

	return { data, maximum = maximum }
end
	runtime.rt_memory_new = rt_memory_new
end

do -- SECTION buffer_read_i32
	local bit, bit_and, bit_lshift, bit_or, bit_rshift, buffer_trap = runtime.bit, runtime.bit_and, runtime.bit_lshift, runtime.bit_or, runtime.bit_rshift, runtime.buffer_trap
-- Returns the signed `bit.tobit` form of the word at the address, which is the
-- form every other `i32` in the runtime already has.
local function buffer_read_i32(buf, base, offset)
	local index = base + offset

	if base < 0 or index + 4 > buf.__n then
		buffer_trap()
	end

	local words = buf.__w
	local slot = bit_rshift(index, 2) + 1
	local shift = bit_lshift(bit_and(index, 3), 3)

	if shift == 0 then
		return words[slot]
	end

	return bit_or(bit_rshift(words[slot], shift), bit_lshift(words[slot + 1], 32 - shift))
end
	runtime.buffer_read_i32 = buffer_read_i32
end

do -- SECTION bit32_or
	local bit = runtime.bit
local bit32_or = bit.bor
	runtime.bit32_or = bit32_or
end

do -- SECTION bit_tobit
	local bit = runtime.bit
local bit_tobit = bit.tobit
	runtime.bit_tobit = bit_tobit
end

do -- SECTION buffer_write_i32
	local bit, bit_and, bit_lshift, bit_or, bit_rshift, bit_tobit, bit_xor, buffer_trap = runtime.bit, runtime.bit_and, runtime.bit_lshift, runtime.bit_or, runtime.bit_rshift, runtime.bit_tobit, runtime.bit_xor, runtime.buffer_trap
-- Accepts either sign of a 32-bit value; the word array always stores the
-- `bit.tobit` form.
local function buffer_write_i32(buf, base, offset, value)
	local index = base + offset

	if base < 0 or index + 4 > buf.__n then
		buffer_trap()
	end

	local words = buf.__w
	local slot = bit_rshift(index, 2) + 1
	local shift = bit_lshift(bit_and(index, 3), 3)
	local word = bit_tobit(value)

	if shift == 0 then
		words[slot] = word

		return
	end

	local high = bit_lshift(-1, shift)
	local low = bit_xor(high, -1)

	words[slot] = bit_or(bit_and(words[slot], low), bit_and(bit_lshift(word, shift), high))
	words[slot + 1] = bit_or(bit_and(words[slot + 1], high), bit_and(bit_rshift(word, 32 - shift), low))
end
	runtime.buffer_write_i32 = buffer_write_i32
end

do -- SECTION store_i32
	local buffer_write_i32 = runtime.buffer_write_i32
local function rt_store_i32(destination, base, offset, source)
	buffer_write_i32(destination[1], base, offset, source)
end
	runtime.rt_store_i32 = rt_store_i32
end

do -- SECTION force_i32
	local bit = runtime.bit
local force_i32 = bit.tobit
	runtime.force_i32 = force_i32
end

do -- SECTION equal_i32
	local force_i32 = runtime.force_i32
local function rt_equal_i32(lhs, rhs)
	return force_i32(lhs) == force_i32(rhs)
end
	runtime.rt_equal_i32 = rt_equal_i32
end

do -- SECTION buffer_write_u8
	local bit_and, bit_lshift, bit_or, bit_rshift, bit_xor, buffer_trap = runtime.bit_and, runtime.bit_lshift, runtime.bit_or, runtime.bit_rshift, runtime.bit_xor, runtime.buffer_trap
local function buffer_write_u8(buf, base, offset, value)
	local index = base + offset

	if base < 0 or index + 1 > buf.__n then
		buffer_trap()
	end

	local words = buf.__w
	local slot = bit_rshift(index, 2) + 1
	local shift = bit_lshift(bit_and(index, 3), 3)

	words[slot] =
		bit_or(bit_and(words[slot], bit_xor(bit_lshift(255, shift), -1)), bit_lshift(bit_and(value, 255), shift))
end
	runtime.buffer_write_u8 = buffer_write_u8
end

do -- SECTION store_i32_into_i8
	local buffer_write_u8 = runtime.buffer_write_u8
local function rt_store_i32_into_i8(destination, base, offset, source)
	buffer_write_u8(destination[1], base, offset, source)
end
	runtime.rt_store_i32_into_i8 = rt_store_i32_into_i8
end

do -- SECTION bit32_and
	local bit = runtime.bit
local bit32_and = bit.band
	runtime.bit32_and = bit32_and
end

do -- SECTION bit32_lshift
	local bit = runtime.bit
local bit32_lshift = bit.lshift
	runtime.bit32_lshift = bit32_lshift
end

do -- SECTION bit32_rshift
	local bit = runtime.bit
local bit32_rshift = bit.rshift
	runtime.bit32_rshift = bit32_rshift
end

do -- SECTION multiply_i32
	local bit32_and, bit32_lshift, bit32_or, bit32_rshift = runtime.bit32_and, runtime.bit32_lshift, runtime.bit32_or, runtime.bit32_rshift
local function rt_multiply_i32(lhs, rhs)
	local a16 = bit32_rshift(lhs, 16)
	local a00 = bit32_and(lhs, 0xFFFF)
	local b16 = bit32_rshift(rhs, 16)
	local b00 = bit32_and(rhs, 0xFFFF)

	local c00 = a00 * b00
	local c16 = a16 * b00 + a00 * b16

	local result = bit32_or(c00 + bit32_lshift(c16, 16), 0)

	return result
end
	runtime.rt_multiply_i32 = rt_multiply_i32
end

do -- SECTION bit32_xor
	local bit = runtime.bit
local bit32_xor = bit.bxor
	runtime.bit32_xor = bit32_xor
end

do -- SECTION exclusive_or_i32
	local bit32_xor = runtime.bit32_xor
local rt_exclusive_or_i32 = bit32_xor
	runtime.rt_exclusive_or_i32 = rt_exclusive_or_i32
end

do -- SECTION not_equal_i32
	local force_i32 = runtime.force_i32
local function rt_not_equal_i32(lhs, rhs)
	return force_i32(lhs) ~= force_i32(rhs)
end
	runtime.rt_not_equal_i32 = rt_not_equal_i32
end

do -- SECTION and_i32
	local bit32_and = runtime.bit32_and
local rt_and_i32 = bit32_and
	runtime.rt_and_i32 = rt_and_i32
end

do -- SECTION buffer_byte
	local bit_and, bit_lshift, bit_rshift, buffer_trap = runtime.bit_and, runtime.bit_lshift, runtime.bit_rshift, runtime.buffer_trap
-- Reads the byte at `base + offset`, where `base` is the address a WebAssembly
-- access computed and `offset` the static offset of the instruction. A negative
-- `base` is out of bounds for every memory we support, and `base + offset` is
-- computed in doubles so it never wraps.
local function buffer_byte(buf, base, offset)
	local index = base + offset

	if base < 0 or index >= buf.__n then
		buffer_trap()
	end

	return bit_and(bit_rshift(buf.__w[bit_rshift(index, 2) + 1], bit_lshift(bit_and(index, 3), 3)), 255)
end
	runtime.buffer_byte = buffer_byte
end

do -- SECTION buffer_read_u8
	local buffer_byte = runtime.buffer_byte
local function buffer_read_u8(buf, base, offset)
	return buffer_byte(buf, base, offset)
end
	runtime.buffer_read_u8 = buffer_read_u8
end

do -- SECTION load_i32_from_u8
	local buffer_read_u8 = runtime.buffer_read_u8
local function rt_load_i32_from_u8(source, base, offset)
	local result = buffer_read_u8(source[1], base, offset)

	return result
end
	runtime.rt_load_i32_from_u8 = rt_load_i32_from_u8
end

do -- SECTION buffer_write_u16
	local bit_and, bit_lshift, bit_or, bit_rshift, bit_xor, buffer_trap = runtime.bit_and, runtime.bit_lshift, runtime.bit_or, runtime.bit_rshift, runtime.bit_xor, runtime.buffer_trap
local function buffer_write_u16(buf, base, offset, value)
	local index = base + offset

	if base < 0 or index + 2 > buf.__n then
		buffer_trap()
	end

	local words = buf.__w
	local slot = bit_rshift(index, 2) + 1
	local shift = bit_lshift(bit_and(index, 3), 3)
	local half = bit_and(value, 65535)

	if shift == 24 then
		words[slot] = bit_or(bit_and(words[slot], 0xFFFFFF), bit_lshift(half, 24))
		words[slot + 1] = bit_or(bit_and(words[slot + 1], -256), bit_rshift(half, 8))

		return
	end

	words[slot] = bit_or(bit_and(words[slot], bit_xor(bit_lshift(65535, shift), -1)), bit_lshift(half, shift))
end
	runtime.buffer_write_u16 = buffer_write_u16
end

do -- SECTION store_i32_into_i16
	local buffer_write_u16 = runtime.buffer_write_u16
local function rt_store_i32_into_i16(destination, base, offset, source)
	buffer_write_u16(destination[1], base, offset, source)
end
	runtime.rt_store_i32_into_i16 = rt_store_i32_into_i16
end

do -- SECTION or_i32
	local bit32_or = runtime.bit32_or
local rt_or_i32 = bit32_or
	runtime.rt_or_i32 = rt_or_i32
end

do -- SECTION force_u32
local function force_u32(source)
	if source >= 0 then
		return source
	else
		return source + 0x100000000
	end
end
	runtime.force_u32 = force_u32
end

do -- SECTION force_s32
	local force_u32 = runtime.force_u32
local function force_s32(source)
	source = force_u32(source)

	if source >= 0x80000000 then
		return source - 0x100000000
	end

	return source
end
	runtime.force_s32 = force_s32
end

do -- SECTION greater_than_s32
	local force_s32 = runtime.force_s32
local function rt_greater_than_s32(lhs, rhs)
	lhs = force_s32(lhs)
	rhs = force_s32(rhs)

	return lhs > rhs
end
	runtime.rt_greater_than_s32 = rt_greater_than_s32
end

do -- SECTION less_than_s32
	local force_s32 = runtime.force_s32
local function rt_less_than_s32(lhs, rhs)
	lhs = force_s32(lhs)
	rhs = force_s32(rhs)

	return lhs < rhs
end
	runtime.rt_less_than_s32 = rt_less_than_s32
end

do -- SECTION shift_right_u32
	local bit32_and, bit32_rshift = runtime.bit32_and, runtime.bit32_rshift
local function rt_shift_right_u32(lhs, rhs)
	rhs = bit32_and(rhs, 0x1F)

	local result = bit32_rshift(lhs, rhs)

	return result
end
	runtime.rt_shift_right_u32 = rt_shift_right_u32
end

do -- SECTION less_than_u32
	local force_u32 = runtime.force_u32
local function rt_less_than_u32(lhs, rhs)
	lhs = force_u32(lhs)
	rhs = force_u32(rhs)

	return lhs < rhs
end
	runtime.rt_less_than_u32 = rt_less_than_u32
end

do -- SECTION shift_left_i32
	local bit32_and, bit32_lshift = runtime.bit32_and, runtime.bit32_lshift
local function rt_shift_left_i32(lhs, rhs)
	rhs = bit32_and(rhs, 0x1F)

	local result = bit32_lshift(lhs, rhs)

	return result
end
	runtime.rt_shift_left_i32 = rt_shift_left_i32
end

do -- SECTION remainder_u32
	local bit32_or, force_u32 = runtime.bit32_or, runtime.force_u32
local function rt_remainder_u32(lhs, rhs)
	lhs = force_u32(lhs)
	rhs = force_u32(rhs)

	if rhs == 0 then
		error("integer divide by zero")
	end

	local result = lhs % rhs

	result = bit32_or(result, 0)

	return result
end
	runtime.rt_remainder_u32 = rt_remainder_u32
end

do -- SECTION math_modf
local math_modf = math.modf
	runtime.math_modf = math_modf
end

do -- SECTION divide_s32
	local bit32_or, force_s32, math_modf = runtime.bit32_or, runtime.force_s32, runtime.math_modf
local function rt_divide_s32(lhs, rhs)
	lhs = force_s32(lhs)
	rhs = force_s32(rhs)

	if rhs == 0 then
		error("integer divide by zero")
	elseif lhs == -0x80000000 and rhs == -1 then
		error("integer overflow")
	end

	local result = lhs / rhs

	result = math_modf(result)
	result = bit32_or(result, 0)

	return result
end
	runtime.rt_divide_s32 = rt_divide_s32
end

do -- SECTION greater_than_u32
	local force_u32 = runtime.force_u32
local function rt_greater_than_u32(lhs, rhs)
	lhs = force_u32(lhs)
	rhs = force_u32(rhs)

	return lhs > rhs
end
	runtime.rt_greater_than_u32 = rt_greater_than_u32
end

do -- SECTION buffer_check
	local buffer_trap = runtime.buffer_trap
-- Traps unless the whole range `[base + offset, base + offset + size)` lies
-- inside `buf`. Multi-word accesses must call this first so a partially
-- in-bounds access never writes or reads anything.
local function buffer_check(buf, base, offset, size)
	if base < 0 or base + offset + size > buf.__n then
		buffer_trap()
	end
end
	runtime.buffer_check = buffer_check
end

do -- SECTION from_bits_i64
local function from_bits_i64(source)
	return source[1], source[2]
end
	runtime.from_bits_i64 = from_bits_i64
end

do -- SECTION store_i64
	local buffer_check, buffer_write_i32, from_bits_i64 = runtime.buffer_check, runtime.buffer_write_i32, runtime.from_bits_i64
local function rt_store_i64(destination, base, offset, source)
	local memory = destination[1]
	local lo, hi = from_bits_i64(source)

	buffer_check(memory, base, offset, 8)
	buffer_write_i32(memory, base, offset, lo)
	buffer_write_i32(memory, base, offset + 4, hi)
end
	runtime.rt_store_i64 = rt_store_i64
end

do -- SECTION into_bits_i64
local function into_bits_i64(lo, hi)
	return { lo % 4294967296, hi % 4294967296 }
end
	runtime.into_bits_i64 = into_bits_i64
end

do -- SECTION less_than_equal_s32
	local force_s32 = runtime.force_s32
local function rt_less_than_equal_s32(lhs, rhs)
	lhs = force_s32(lhs)
	rhs = force_s32(rhs)

	return lhs <= rhs
end
	runtime.rt_less_than_equal_s32 = rt_less_than_equal_s32
end

do -- SECTION divide_u32
	local bit32_or, force_u32, math_floor = runtime.bit32_or, runtime.force_u32, runtime.math_floor
local function rt_divide_u32(lhs, rhs)
	lhs = force_u32(lhs)
	rhs = force_u32(rhs)

	if rhs == 0 then
		error("integer divide by zero")
	end

	local result = math_floor(lhs / rhs)

	result = bit32_or(result, 0)

	return result
end
	runtime.rt_divide_u32 = rt_divide_u32
end

do -- SECTION greater_than_equal_s32
	local force_s32 = runtime.force_s32
local function rt_greater_than_equal_s32(lhs, rhs)
	lhs = force_s32(lhs)
	rhs = force_s32(rhs)

	return lhs >= rhs
end
	runtime.rt_greater_than_equal_s32 = rt_greater_than_equal_s32
end

do -- SECTION math_fmod
local math_fmod = math.fmod
	runtime.math_fmod = math_fmod
end

do -- SECTION remainder_s32
	local bit32_or, force_s32, math_fmod = runtime.bit32_or, runtime.force_s32, runtime.math_fmod
local function rt_remainder_s32(lhs, rhs)
	lhs = force_s32(lhs)
	rhs = force_s32(rhs)

	if rhs == 0 then
		error("integer divide by zero")
	end

	local result = math_fmod(lhs, rhs)

	result = bit32_or(result, 0)

	return result
end
	runtime.rt_remainder_s32 = rt_remainder_s32
end

do -- SECTION table_new
local function rt_table_new(initializer, minimum, maximum)
	local result = {}

	for offset, element in pairs(initializer) do
		result[offset] = element
	end

	result.minimum = minimum
	result.maximum = maximum

	return result
end
	runtime.rt_table_new = rt_table_new
end

do -- SECTION buffer_copy
	local bit_and, bit_lshift, bit_or, bit_rshift, bit_xor, buffer_trap = runtime.bit_and, runtime.bit_lshift, runtime.bit_or, runtime.bit_rshift, runtime.bit_xor, runtime.buffer_trap
-- Moves `size` bytes, with `memmove` semantics when the two ranges overlap.
--
-- The fast path copies whole words and needs the two addresses to share their
-- alignment; it also needs the copy to run forwards, which an overlap only
-- allows when the destination is at or below the source.
local function buffer_copy(dest, dest_offset, src, offset, size)
	if
		size < 0
		or dest_offset < 0
		or offset < 0
		or dest_offset + size > dest.__n
		or offset + size > src.__n
	then
		buffer_trap()
	end

	if size == 0 then
		return
	end

	local dest_words = dest.__w
	local src_words = src.__w
	local backwards = dest == src and dest_offset > offset

	if not backwards and bit_and(bit_xor(dest_offset, offset), 3) == 0 then
		local head = bit_and(-dest_offset, 3)

		if head > size then
			head = size
		end

		for k = 0, head - 1 do
			local from = offset + k
			local to = dest_offset + k
			local value = bit_and(bit_rshift(src_words[bit_rshift(from, 2) + 1], bit_lshift(bit_and(from, 3), 3)), 255)
			local index = bit_rshift(to, 2) + 1
			local shift = bit_lshift(bit_and(to, 3), 3)

			dest_words[index] =
				bit_or(bit_and(dest_words[index], bit_xor(bit_lshift(255, shift), -1)), bit_lshift(value, shift))
		end

		local count = bit_rshift(size - head, 2)
		local to_index = bit_rshift(dest_offset + head, 2)
		local from_index = bit_rshift(offset + head, 2)

		for k = 1, count do
			dest_words[to_index + k] = src_words[from_index + k]
		end

		for k = head + count * 4, size - 1 do
			local from = offset + k
			local to = dest_offset + k
			local value = bit_and(bit_rshift(src_words[bit_rshift(from, 2) + 1], bit_lshift(bit_and(from, 3), 3)), 255)
			local index = bit_rshift(to, 2) + 1
			local shift = bit_lshift(bit_and(to, 3), 3)

			dest_words[index] =
				bit_or(bit_and(dest_words[index], bit_xor(bit_lshift(255, shift), -1)), bit_lshift(value, shift))
		end

		return
	end

	local first = 0
	local last = size - 1
	local step = 1

	if backwards then
		first = size - 1
		last = 0
		step = -1
	end

	for k = first, last, step do
		local from = offset + k
		local to = dest_offset + k
		local value = bit_and(bit_rshift(src_words[bit_rshift(from, 2) + 1], bit_lshift(bit_and(from, 3), 3)), 255)
		local index = bit_rshift(to, 2) + 1
		local shift = bit_lshift(bit_and(to, 3), 3)

		dest_words[index] =
			bit_or(bit_and(dest_words[index], bit_xor(bit_lshift(255, shift), -1)), bit_lshift(value, shift))
	end
end
	runtime.buffer_copy = buffer_copy
end

do -- SECTION buffer_len
local function buffer_len(buf)
	return buf.__n
end
	runtime.buffer_len = buffer_len
end

do -- SECTION memory_copy
	local buffer_copy = runtime.buffer_copy
local function rt_memory_copy(destination, offset_1, source, offset_2, size)
	buffer_copy(destination[1], offset_1, source[1], offset_2, size)
end
	runtime.rt_memory_copy = rt_memory_copy
end

do -- SECTION memory_drop
	local buffer_create = runtime.buffer_create
local function rt_memory_drop(destination)
	destination[1] = buffer_create(0)
	destination.maximum = 0
end
	runtime.rt_memory_drop = rt_memory_drop
end

do -- SECTION buffer_fill
	local bit_and, bit_lshift, bit_or, bit_rshift, bit_tobit, bit_xor, buffer_trap = runtime.bit_and, runtime.bit_lshift, runtime.bit_or, runtime.bit_rshift, runtime.bit_tobit, runtime.bit_xor, runtime.buffer_trap
local function buffer_fill(buf, offset, value, size)
	if size < 0 or offset < 0 or offset + size > buf.__n then
		buffer_trap()
	end

	if size == 0 then
		return
	end

	local words = buf.__w
	local byte = bit_and(value, 255)
	local word = bit_tobit(byte * 16843009)
	local address = offset
	local last = offset + size

	while address < last and bit_and(address, 3) ~= 0 do
		local index = bit_rshift(address, 2) + 1
		local shift = bit_lshift(bit_and(address, 3), 3)

		words[index] = bit_or(bit_and(words[index], bit_xor(bit_lshift(255, shift), -1)), bit_lshift(byte, shift))
		address = address + 1
	end

	while address + 4 <= last do
		words[bit_rshift(address, 2) + 1] = word
		address = address + 4
	end

	while address < last do
		local index = bit_rshift(address, 2) + 1
		local shift = bit_lshift(bit_and(address, 3), 3)

		words[index] = bit_or(bit_and(words[index], bit_xor(bit_lshift(255, shift), -1)), bit_lshift(byte, shift))
		address = address + 1
	end
end
	runtime.buffer_fill = buffer_fill
end

do -- SECTION f32_constants
-- Constants shared by the `binary32` conversions.
--
-- `F32_POWERS[k + 150]` is `2 ^ k` for every `k` in `-149 .. 128`. It is built
-- by exact doubling and halving, so no `pow` call and no rounding is involved,
-- and it replaces the `2 ^ exponent` expressions the conversions would
-- otherwise evaluate on every call.
--
-- `SPLIT_F32` is the Veltkamp split factor `2 ^ 29 + 1`: for a finite double of
-- `binary32` magnitude, `c = x * SPLIT_F32` followed by `c - (c - x)` is the
-- correctly rounded `binary32` value of `x`. That replaces `math.frexp`, which
-- the `LuaJIT` tracer cannot compile and which therefore split a trace on every
-- conversion.
--
-- `SUB_MAGIC_F32` is `1.5 * 2 ^ 52 * 2 ^ -149`; adding and subtracting it
-- rounds a value to a multiple of the smallest subnormal with the same
-- round-half-to-even rule. `OVERFLOW_F32` is the first double that rounds up to
-- infinity, and `SCALE_F32` turns a rounded subnormal into its integer
-- mantissa.
local F32_POWERS = {}
local SPLIT_F32 = 2 ^ 29 + 1
local MIN_NORMAL_F32 = 2 ^ -126
local SUB_MAGIC_F32 = 1.5 * 2 ^ -97
local OVERFLOW_F32 = 2 ^ 128 - 2 ^ 103
local SCALE_F32 = 2 ^ 149
do
	local value = 1.0

	for k = 0, 128 do
		F32_POWERS[k + 150] = value
		value = value * 2
	end

	value = 1.0

	for k = -1, -149, -1 do
		value = value / 2
		F32_POWERS[k + 150] = value
	end
end
	runtime.F32_POWERS = F32_POWERS
	runtime.SPLIT_F32 = SPLIT_F32
	runtime.MIN_NORMAL_F32 = MIN_NORMAL_F32
	runtime.SUB_MAGIC_F32 = SUB_MAGIC_F32
	runtime.OVERFLOW_F32 = OVERFLOW_F32
	runtime.SCALE_F32 = SCALE_F32
end

do -- SECTION math_huge
local math_huge = math.huge
	runtime.math_huge = math_huge
end

do -- SECTION from_bits_f32
	local F32_POWERS, bit, bit_and, bit_rshift, math_huge = runtime.F32_POWERS, runtime.bit, runtime.bit_and, runtime.bit_rshift, runtime.math_huge
-- Turns a `binary32` bit pattern into a double. The pattern may carry either
-- sign, since `bit.rshift` normalises it first.
local function from_bits_f32(source)
	local exponent = bit_and(bit_rshift(source, 23), 0xFF)
	local mantissa = bit_and(source, 0x7FFFFF)
	local result

	if exponent == 0xFF then
		if mantissa ~= 0 then
			return 0 / 0
		end

		result = math_huge
	elseif exponent == 0 then
		-- `2 ^ -149` scaled, which is exact for every subnormal mantissa.
		result = mantissa * F32_POWERS[1]
	else
		-- `(2 ^ 23 + mantissa) * 2 ^ (exponent - 150)`, and `exponent - 150`
		-- lands at table index `exponent`.
		result = (mantissa + 0x800000) * F32_POWERS[exponent]
	end

	if bit_and(bit_rshift(source, 31), 1) ~= 0 then
		return -result
	end

	return result
end
	runtime.from_bits_f32 = from_bits_f32
end

do -- SECTION buffer_read_f32
	local buffer_read_i32, from_bits_f32 = runtime.buffer_read_i32, runtime.from_bits_f32
local function buffer_read_f32(buf, base, offset)
	return from_bits_f32(buffer_read_i32(buf, base, offset))
end
	runtime.buffer_read_f32 = buffer_read_f32
end

do -- SECTION from_bits_f64
-- `-0.0` is read from this local instead of written as a literal: LuaJIT
-- 2.1.0-beta3 turns a `-0.0` constant inside a compiled trace into `+0.0`,
-- while a value loaded from a variable keeps its sign.
local NEGATIVE_ZERO = -0.0

local function from_bits_f64(lo, hi)
	lo = lo % 4294967296
	hi = hi % 4294967296

	local sign = hi >= 0x80000000
	local exponent = math.floor((hi % 0x80000000) / 0x100000)
	local mantissa_high = hi % 0x100000
	local mantissa = mantissa_high * 4294967296.0 + lo

	if exponent == 0 then
		if mantissa == 0 then
			if sign then
				return NEGATIVE_ZERO
			end

			return 0.0
		end

		local result = mantissa * 2 ^ -1074

		if sign then
			return -result
		end

		return result
	end

	if exponent == 0x7FF then
		if mantissa == 0 then
			if sign then
				return -math.huge
			end

			return math.huge
		end

		return 0 / 0
	end

	local result = (1 + mantissa / 4503599627370496.0) * 2 ^ (exponent - 1023)

	if sign then
		return -result
	end

	return result
end
	runtime.NEGATIVE_ZERO = NEGATIVE_ZERO
	runtime.from_bits_f64 = from_bits_f64
end

do -- SECTION buffer_read_f64
	local buffer_check, buffer_read_i32, from_bits_f64 = runtime.buffer_check, runtime.buffer_read_i32, runtime.from_bits_f64
local function buffer_read_f64(buf, base, offset)
	buffer_check(buf, base, offset, 8)

	local lo = buffer_read_i32(buf, base, offset)
	local hi = buffer_read_i32(buf, base, offset + 4)

	return from_bits_f64(lo, hi)
end
	runtime.buffer_read_f64 = buffer_read_f64
end

do -- SECTION buffer_read_u16
	local bit_and, bit_lshift, bit_or, bit_rshift, buffer_trap = runtime.bit_and, runtime.bit_lshift, runtime.bit_or, runtime.bit_rshift, runtime.buffer_trap
local function buffer_read_u16(buf, base, offset)
	local index = base + offset

	if base < 0 or index + 2 > buf.__n then
		buffer_trap()
	end

	local words = buf.__w
	local slot = bit_rshift(index, 2) + 1
	local shift = bit_lshift(bit_and(index, 3), 3)

	if shift == 24 then
		return bit_or(bit_rshift(words[slot], 24), bit_lshift(bit_and(words[slot + 1], 255), 8))
	end

	return bit_and(bit_rshift(words[slot], shift), 65535)
end
	runtime.buffer_read_u16 = buffer_read_u16
end

do -- SECTION buffer_read_i16
	local buffer_read_u16 = runtime.buffer_read_u16
local function buffer_read_i16(buf, base, offset)
	local value = buffer_read_u16(buf, base, offset)

	if value >= 32768 then
		return value - 65536
	end

	return value
end
	runtime.buffer_read_i16 = buffer_read_i16
end

do -- SECTION buffer_read_i8
	local buffer_byte = runtime.buffer_byte
local function buffer_read_i8(buf, base, offset)
	local value = buffer_byte(buf, base, offset)

	if value >= 128 then
		return value - 256
	end

	return value
end
	runtime.buffer_read_i8 = buffer_read_i8
end

do -- SECTION math_log
local math_log = math.log
	runtime.math_log = math_log
end

do -- SECTION into_bits_f32
	local F32_POWERS, MIN_NORMAL_F32, OVERFLOW_F32, SCALE_F32, SPLIT_F32, SUB_MAGIC_F32, bit, math_floor, math_log = runtime.F32_POWERS, runtime.MIN_NORMAL_F32, runtime.OVERFLOW_F32, runtime.SCALE_F32, runtime.SPLIT_F32, runtime.SUB_MAGIC_F32, runtime.bit, runtime.math_floor, runtime.math_log
-- Rounds a double to `binary32` and returns its bit pattern, signed so that it
-- matches every other `i32` the runtime produces.
--
-- The rounding is a Veltkamp split rather than `math.frexp`, and the exponent
-- comes from a logarithm corrected by at most one step, so the whole function
-- compiles into a trace.
local function into_bits_f32(source)
	if source ~= source then
		return 0x7FC00000
	end

	local sign_bit = 0

	if source < 0 or 1 / source < 0 then
		sign_bit = 0x80000000
		source = -source
	end

	local result

	if source >= OVERFLOW_F32 then
		result = sign_bit + 0x7F800000
	elseif source < MIN_NORMAL_F32 then
		-- Subnormal or zero. The magic add rounds to a multiple of `2 ^ -149`,
		-- and scaling that back is exact. A value that rounds up to `2 ^ -126`
		-- yields a mantissa of `0x800000`, which is already the encoding of the
		-- smallest normal.
		result = sign_bit + ((source + SUB_MAGIC_F32) - SUB_MAGIC_F32) * SCALE_F32
	else
		local split = source * SPLIT_F32
		local rounded = split - (split - source)
		local exponent = math_floor(math_log(rounded) * 1.4426950408889634)
		local scale = F32_POWERS[exponent + 150]

		-- The logarithm is only accurate to within one exponent, so correct it.
		if rounded < scale then
			exponent = exponent - 1
			scale = F32_POWERS[exponent + 150]
		elseif rounded >= scale + scale then
			exponent = exponent + 1
			scale = F32_POWERS[exponent + 150]
		end

		-- Dividing by a power of two is exact, and the rounded value is already
		-- a `binary32`, so the mantissa comes out as an exact integer.
		result = sign_bit + (exponent + 127) * 0x800000 + (rounded / scale - 1) * 0x800000
	end

	if result >= 2147483648 then
		return result - 4294967296
	end

	return result
end
	runtime.into_bits_f32 = into_bits_f32
end

do -- SECTION buffer_write_f32
	local buffer_write_i32, into_bits_f32 = runtime.buffer_write_i32, runtime.into_bits_f32
local function buffer_write_f32(buf, base, offset, value)
	buffer_write_i32(buf, base, offset, into_bits_f32(value))
end
	runtime.buffer_write_f32 = buffer_write_f32
end

do -- SECTION into_bits_f64
local function into_bits_f64(source)
	if source ~= source then
		return 0, 0x7FF80000
	end

	if source == math.huge then
		return 0, 0x7FF00000
	end

	if source == -math.huge then
		return 0, 0xFFF00000
	end

	local sign_bit = 0

	if source < 0 or 1 / source < 0 then
		sign_bit = 0x80000000
		source = -source
	end

	if source == 0 then
		return 0, sign_bit
	end

	local mantissa, exponent = math.frexp(source)

	exponent = exponent + 1022

	if exponent >= 0x7FF then
		return 0, sign_bit + 0x7FF00000
	end

	if exponent <= 0 then
		mantissa = math.floor(mantissa * 2 ^ (exponent + 52))

		local hi = sign_bit + math.floor(mantissa / 4294967296.0)
		local lo = mantissa % 4294967296.0

		return lo % 4294967296, hi % 4294967296
	end

	mantissa = math.floor((mantissa - 0.5) * 2 ^ 53)

	local hi = sign_bit + exponent * 0x100000 + math.floor(mantissa / 4294967296.0)
	local lo = mantissa % 4294967296.0

	return lo % 4294967296, hi % 4294967296
end
	runtime.into_bits_f64 = into_bits_f64
end

do -- SECTION buffer_write_f64
	local buffer_check, buffer_write_i32, into_bits_f64 = runtime.buffer_check, runtime.buffer_write_i32, runtime.into_bits_f64
local function buffer_write_f64(buf, base, offset, value)
	buffer_check(buf, base, offset, 8)

	local lo, hi = into_bits_f64(value)

	buffer_write_i32(buf, base, offset, lo)
	buffer_write_i32(buf, base, offset + 4, hi)
end
	runtime.buffer_write_f64 = buffer_write_f64
end

do -- SECTION yield_point
-- Cooperative yield points (`spider-cli --yield-every N`): every loop iteration
-- decrements a module-local budget and, when it runs out, calls this function,
-- which runs the host hook (set with `__host.set_yield_hook`) and returns the next
-- budget. The hook may `coroutine.yield()` if the module is driven by a coroutine.
local yield_state = { hook = nil, every = 100000 }
local function rt_yield_point()
	local hook = yield_state.hook
	if hook then
		hook()
	end
	return yield_state.every
end
	runtime.yield_state = yield_state
	runtime.rt_yield_point = rt_yield_point
end

do -- SECTION buffer
	local bit = runtime.bit
-- A memory image is a table with two raw fields:
--   `__n`: the logical byte length,
--   `__w`: a dense array of packed 32-bit words, indexed from one, each holding
--          the `bit.tobit` (signed) form of four little endian bytes.
--
-- Byte `a` lives in word `bit.rshift(a, 2) + 1` at bit offset
-- `bit.lshift(bit.band(a, 3), 3)`, which is the little endian layout
-- WebAssembly specifies. The word array is always two slots longer than the
-- length strictly needs, so an unaligned access that straddles the final word
-- still finds a slot to read.
--
-- Every 32-bit read returns the signed `bit.tobit` form, which is the single
-- `i32` representation the whole runtime uses; no load is ever fixed up
-- afterwards. Reads narrower than a word stay unsigned (`0 .. 255`,
-- `0 .. 65535`), which is also a valid `i32` because those values are positive.
local buffer = {}
	runtime.buffer = buffer
end

do -- SECTION host_api
	local bit_and, bit_rshift, buffer, buffer_fill, buffer_len, buffer_read_f32, buffer_read_f64, buffer_read_i16, buffer_read_i32, buffer_read_i8, buffer_read_u16, buffer_read_u8, buffer_write_f32, buffer_write_f64, buffer_write_i32, buffer_write_u16, buffer_write_u8, buffer_writestring, yield_state = runtime.bit_and, runtime.bit_rshift, runtime.buffer, runtime.buffer_fill, runtime.buffer_len, runtime.buffer_read_f32, runtime.buffer_read_f64, runtime.buffer_read_i16, runtime.buffer_read_i32, runtime.buffer_read_i8, runtime.buffer_read_u16, runtime.buffer_read_u8, runtime.buffer_write_f32, runtime.buffer_write_f64, runtime.buffer_write_i32, runtime.buffer_write_u16, runtime.buffer_write_u8, runtime.buffer_writestring, runtime.yield_state
-- Host-facing access to linear memory, the same for every memory backend.
--
-- Every module exports this table as `__host`. Functions take the exported
-- memory object (`exports.memory`) rather than its internal buffer, because a
-- `memory.grow` may replace the buffer; addresses are byte offsets from 0.
-- Out-of-range accesses trap exactly like loads and stores in the module.
local host_api = {}
do
	local char, concat, unpack = string.char, table.concat, unpack or table.unpack

	function host_api.size(memory)
		return buffer_len(memory[1])
	end

	function host_api.read_u8(memory, ptr) return buffer_read_u8(memory[1], ptr, 0) end
	function host_api.read_i8(memory, ptr) return buffer_read_i8(memory[1], ptr, 0) end
	function host_api.read_u16(memory, ptr) return buffer_read_u16(memory[1], ptr, 0) end
	function host_api.read_i16(memory, ptr) return buffer_read_i16(memory[1], ptr, 0) end
	function host_api.read_i32(memory, ptr) return buffer_read_i32(memory[1], ptr, 0) end
	function host_api.read_f32(memory, ptr) return buffer_read_f32(memory[1], ptr, 0) end
	function host_api.read_f64(memory, ptr) return buffer_read_f64(memory[1], ptr, 0) end

	function host_api.read_u32(memory, ptr)
		local value = buffer_read_i32(memory[1], ptr, 0)
		if value < 0 then
			value = value + 0x100000000
		end
		return value
	end

	function host_api.write_u8(memory, ptr, value) buffer_write_u8(memory[1], ptr, 0, value) end
	function host_api.write_u16(memory, ptr, value) buffer_write_u16(memory[1], ptr, 0, value) end
	function host_api.write_i32(memory, ptr, value) buffer_write_i32(memory[1], ptr, 0, value) end
	function host_api.write_f32(memory, ptr, value) buffer_write_f32(memory[1], ptr, 0, value) end
	function host_api.write_f64(memory, ptr, value) buffer_write_f64(memory[1], ptr, 0, value) end

	-- Copies `length` bytes starting at `ptr` into `dst[dst_offset + i]`, i = 0..length-1.
	-- `dst` is anything indexable by number: a Lua table, `Bytearray.bytes`, an ffi pointer.
	function host_api.copy_out(memory, ptr, length, dst, dst_offset)
		local buf = memory[1]
		dst_offset = dst_offset or 0
		local i = 0
		while i < length and (ptr + i) % 4 ~= 0 do
			dst[dst_offset + i] = buffer_read_u8(buf, ptr + i, 0)
			i = i + 1
		end
		while i + 4 <= length do
			local word = buffer_read_i32(buf, ptr + i, 0)
			local o = dst_offset + i
			dst[o] = bit_and(word, 255)
			dst[o + 1] = bit_and(bit_rshift(word, 8), 255)
			dst[o + 2] = bit_and(bit_rshift(word, 16), 255)
			dst[o + 3] = bit_rshift(word, 24)
			i = i + 4
		end
		while i < length do
			dst[dst_offset + i] = buffer_read_u8(buf, ptr + i, 0)
			i = i + 1
		end
	end

	-- Copies `length` bytes from `src[src_offset + i]` into memory at `ptr`.
	function host_api.copy_in(memory, ptr, src, src_offset, length)
		local buf = memory[1]
		src_offset = src_offset or 0
		local i = 0
		while i < length and (ptr + i) % 4 ~= 0 do
			buffer_write_u8(buf, ptr + i, 0, src[src_offset + i])
			i = i + 1
		end
		while i + 4 <= length do
			local o = src_offset + i
			buffer_write_i32(buf, ptr + i, 0, src[o] + src[o + 1] * 256 + src[o + 2] * 65536 + src[o + 3] * 16777216)
			i = i + 4
		end
		while i < length do
			buffer_write_u8(buf, ptr + i, 0, src[src_offset + i])
			i = i + 1
		end
	end

	-- Bytes `ptr .. ptr + length - 1` as a Lua string.
	function host_api.read_string(memory, ptr, length)
		local bytes = {}
		host_api.copy_out(memory, ptr, length, bytes, 1)
		local parts = {}
		for first = 1, length, 4096 do
			parts[#parts + 1] = char(unpack(bytes, first, math.min(first + 4095, length)))
		end
		return concat(parts)
	end

	-- Zero-terminated string at `ptr` (at most `limit` bytes, 65536 by default).
	function host_api.read_cstring(memory, ptr, limit)
		local buf = memory[1]
		limit = limit or 65536
		local length = 0
		while length < limit and buffer_read_u8(buf, ptr + length, 0) ~= 0 do
			length = length + 1
		end
		return host_api.read_string(memory, ptr, length)
	end

	-- Writes the bytes of a Lua string at `ptr`.
	function host_api.write_string(memory, ptr, text)
		if #text > 0 then
			buffer_writestring(memory[1], ptr, text)
		end
	end

	function host_api.fill(memory, ptr, value, length)
		buffer_fill(memory[1], ptr, value, length)
	end

	-- Hook called at yield points (only in modules built with `--yield-every`):
	-- roughly every `every` loop iterations. `nil` removes the hook.
	function host_api.set_yield_hook(hook, every)
		yield_state.hook = hook
		if every then
			yield_state.every = every
		end
	end

	-- Whether the module was built with yield points.
	host_api.has_yield_points = false
end
	runtime.host_api = host_api
end

local function module(loc_97_)
	local excess_stack = { top = 0 }
	local rt_and_i32 = runtime.rt_and_i32
	local bit32_or = runtime.bit32_or
	local buffer_read_i32 = runtime.buffer_read_i32
	local rt_divide_s32 = runtime.rt_divide_s32
	local rt_divide_u32 = runtime.rt_divide_u32
	local rt_equal_i32 = runtime.rt_equal_i32
	local rt_exclusive_or_i32 = runtime.rt_exclusive_or_i32
	local rt_function_type = runtime.rt_function_type
	local rt_greater_than_equal_s32 = runtime.rt_greater_than_equal_s32
	local rt_greater_than_s32 = runtime.rt_greater_than_s32
	local rt_greater_than_u32 = runtime.rt_greater_than_u32
	local into_bits_i64 = runtime.into_bits_i64
	local rt_less_than_equal_s32 = runtime.rt_less_than_equal_s32
	local rt_less_than_s32 = runtime.rt_less_than_s32
	local rt_less_than_u32 = runtime.rt_less_than_u32
	local rt_load_i32_from_u8 = runtime.rt_load_i32_from_u8
	local rt_memory_copy = runtime.rt_memory_copy
	local rt_memory_drop = runtime.rt_memory_drop
	local rt_memory_new = runtime.rt_memory_new
	local rt_multiply_i32 = runtime.rt_multiply_i32
	local rt_not_equal_i32 = runtime.rt_not_equal_i32
	local rt_or_i32 = runtime.rt_or_i32
	local rt_remainder_s32 = runtime.rt_remainder_s32
	local rt_remainder_u32 = runtime.rt_remainder_u32
	local rt_shift_left_i32 = runtime.rt_shift_left_i32
	local rt_shift_right_u32 = runtime.rt_shift_right_u32
	local rt_store_i32 = runtime.rt_store_i32
	local rt_store_i32_into_i16 = runtime.rt_store_i32_into_i16
	local rt_store_i32_into_i8 = runtime.rt_store_i32_into_i8
	local rt_store_i64 = runtime.rt_store_i64
	local rt_table_new = runtime.rt_table_new
	local loc_98_, loc_99_, loc_100_, loc_101_, loc_102_, loc_103_, loc_104_, loc_105_, loc_106_, loc_107_, loc_108_, loc_109_, loc_110_, loc_111_, loc_112_, loc_113_, loc_114_, loc_115_, loc_116_, loc_117_, loc_118_, loc_119_, loc_120_, loc_121_, loc_122_, loc_123_, loc_124_, loc_125_
	loc_105_ = { assert(loc_97_["vc"]["time_ms"], '`vc.time_ms` should be present') };
	loc_106_ = { assert(loc_97_["vc"]["audio_open"], '`vc.audio_open` should be present') };
	loc_107_ = { assert(loc_97_["vc"]["gfx_texture"], '`vc.gfx_texture` should be present') };
	loc_108_ = { assert(loc_97_["vc"]["log"], '`vc.log` should be present') };
	loc_109_ = { assert(loc_97_["vc"]["key_down"], '`vc.key_down` should be present') };
	loc_110_ = { assert(loc_97_["vc"]["mouse"], '`vc.mouse` should be present') };
	loc_111_ = { assert(loc_97_["vc"]["gfx_submit"], '`vc.gfx_submit` should be present') };
	loc_112_ = { assert(loc_97_["vc"]["audio_write"], '`vc.audio_write` should be present') };
	loc_113_ = { nil };
	loc_113_[1] = rt_function_type((function(loc_0_)
		local loc_1_
		loc_1_ = loc_0_;
		return loc_1_
	end), "->");
	loc_104_ = { nil };
	loc_119_ = { nil };
	loc_123_ = { nil };
	loc_100_ = rt_memory_new({ }, 131072, 4294967295);
	loc_104_[1] = (function(loc_2_, loc_3_, loc_4_, loc_5_)
		return rt_function_type((function(loc_6_)
			local loc_7_, loc_8_, loc_9_, loc_10_, loc_11_, loc_12_, loc_13_, loc_14_
			loc_14_ = loc_4_[1];
			loc_8_ = loc_4_;
			loc_14_ = buffer_read_i32(loc_5_[1], bit32_or(loc_14_ + 1248, 0), 0);
			loc_9_ = loc_5_;
			if rt_equal_i32(loc_14_, 0) then
				loc_7_ = loc_6_;
				loc_12_ = loc_2_;
				loc_13_ = loc_3_;
				loc_10_ = loc_12_;
				loc_11_ = loc_13_;
				loc_14_ = loc_8_[1];
				rt_store_i32(loc_9_, bit32_or(loc_14_ + 1248, 0), 0, 1)
				loc_13_[1](loc_7_)
				loc_12_[1](loc_7_)
			else
				loc_7_ = loc_6_;
				loc_12_ = loc_2_;
				loc_13_ = loc_3_;
				loc_10_ = loc_12_;
				loc_11_ = loc_13_;
				loc_14_ = error('unreachable code');
			end
			return loc_7_
		end), "->")
	end)(loc_113_, loc_119_, loc_123_, loc_100_);
	loc_103_ = { nil };
	loc_103_[1] = (function(loc_15_, loc_16_, loc_17_, loc_18_, loc_19_)
		return rt_function_type((function(loc_20_)
			local loc_21_, loc_22_, loc_23_, loc_24_, loc_25_, loc_26_, loc_27_, loc_28_, loc_29_, loc_30_, loc_31_, loc_32_, loc_33_
			loc_22_ = loc_19_;
			loc_33_ = loc_20_;
			loc_32_ = loc_15_[1](loc_33_)
			rt_store_i32(loc_22_, 0, 1268, 20992)
			rt_store_i32(loc_22_, 0, 1264, 20992)
			rt_store_i32(loc_22_, 0, 1280, 40960)
			rt_store_i32(loc_22_, 0, 1284, 25600)
			rt_store_i32_into_i8(loc_22_, 0, 1296, 1)
			loc_32_ = bit32_or(rt_multiply_i32(rt_exclusive_or_i32(loc_32_, -1640531527), 1103515245) + 12345, 0);
			rt_store_i32(loc_22_, 0, 1228, loc_32_)
			loc_30_ = 0;
			loc_31_ = 1;
			loc_29_ = -1;
			if rt_not_equal_i32(rt_and_i32(loc_32_, 65536), 0) then
				loc_23_ = loc_18_;
				loc_24_ = loc_17_;
				loc_25_ = loc_15_;
				loc_32_ = loc_16_;
			else
				loc_23_ = loc_18_;
				loc_24_ = loc_17_;
				loc_25_ = loc_15_;
				loc_32_ = loc_16_;
				loc_31_ = loc_29_;
			end
			loc_26_ = loc_32_;
			rt_store_i32(loc_22_, loc_30_, 1300, loc_31_)
			rt_store_i32(loc_22_, 0, 1260, 0)
			rt_store_i32(loc_22_, 0, 1256, 0)
			rt_store_i32(loc_22_, 0, 1272, 0)
			rt_store_i32(loc_22_, 0, 1276, 0)
			rt_store_i32(loc_22_, 0, 1288, 0)
			rt_store_i32(loc_22_, 0, 1292, 0)
			loc_33_ = loc_32_[1](22050, 1, loc_33_)
			rt_store_i32(loc_22_, 0, 1252, loc_33_)
			loc_27_ = 0;
			loc_28_ = 1184;
			repeat
				loc_32_ = buffer_read_i32(loc_22_[1], loc_28_, 0);
				loc_29_ = rt_load_i32_from_u8(loc_22_, loc_32_, 0);
				rt_store_i32_into_i8(loc_22_, bit32_or(loc_27_ + 1314, 0), 0, 106)
				rt_store_i32_into_i16(loc_22_, bit32_or(loc_27_ + 1312, 0), 0, 53850)
				loc_31_ = bit32_or(loc_27_ + 1315, 0);
				loc_33_ = -1;
				loc_30_ = 0;
				if rt_equal_i32(loc_29_, 35) then
					loc_29_ = loc_27_;
				else
					loc_29_ = loc_27_;
					loc_33_ = loc_30_;
				end
				rt_store_i32_into_i8(loc_22_, loc_31_, 0, loc_33_)
				loc_27_ = rt_load_i32_from_u8(loc_22_, loc_32_, 1);
				rt_store_i32_into_i8(loc_22_, bit32_or(loc_29_ + 1318, 0), 0, 106)
				rt_store_i32_into_i16(loc_22_, bit32_or(loc_29_ + 1316, 0), 0, 53850)
				loc_31_ = bit32_or(loc_29_ + 1319, 0);
				loc_33_ = -1;
				loc_30_ = 0;
				if not (rt_equal_i32(loc_27_, 35)) then
					loc_33_ = loc_30_;
				end
				rt_store_i32_into_i8(loc_22_, loc_31_, 0, loc_33_)
				loc_27_ = rt_load_i32_from_u8(loc_22_, loc_32_, 2);
				rt_store_i32_into_i8(loc_22_, bit32_or(loc_29_ + 1322, 0), 0, 106)
				rt_store_i32_into_i16(loc_22_, bit32_or(loc_29_ + 1320, 0), 0, 53850)
				loc_31_ = bit32_or(loc_29_ + 1323, 0);
				loc_33_ = -1;
				loc_30_ = 0;
				if not (rt_equal_i32(loc_27_, 35)) then
					loc_33_ = loc_30_;
				end
				rt_store_i32_into_i8(loc_22_, loc_31_, 0, loc_33_)
				loc_27_ = rt_load_i32_from_u8(loc_22_, loc_32_, 3);
				rt_store_i32_into_i8(loc_22_, bit32_or(loc_29_ + 1326, 0), 0, 106)
				rt_store_i32_into_i16(loc_22_, bit32_or(loc_29_ + 1324, 0), 0, 53850)
				loc_31_ = bit32_or(loc_29_ + 1327, 0);
				loc_33_ = -1;
				loc_30_ = 0;
				if not (rt_equal_i32(loc_27_, 35)) then
					loc_33_ = loc_30_;
				end
				rt_store_i32_into_i8(loc_22_, loc_31_, 0, loc_33_)
				loc_27_ = rt_load_i32_from_u8(loc_22_, loc_32_, 4);
				rt_store_i32_into_i8(loc_22_, bit32_or(loc_29_ + 1330, 0), 0, 106)
				rt_store_i32_into_i16(loc_22_, bit32_or(loc_29_ + 1328, 0), 0, 53850)
				loc_31_ = bit32_or(loc_29_ + 1331, 0);
				loc_33_ = -1;
				loc_30_ = 0;
				if not (rt_equal_i32(loc_27_, 35)) then
					loc_33_ = loc_30_;
				end
				rt_store_i32_into_i8(loc_22_, loc_31_, 0, loc_33_)
				loc_27_ = rt_load_i32_from_u8(loc_22_, loc_32_, 5);
				rt_store_i32_into_i8(loc_22_, bit32_or(loc_29_ + 1334, 0), 0, 106)
				rt_store_i32_into_i16(loc_22_, bit32_or(loc_29_ + 1332, 0), 0, 53850)
				loc_31_ = bit32_or(loc_29_ + 1335, 0);
				loc_33_ = -1;
				loc_30_ = 0;
				if not (rt_equal_i32(loc_27_, 35)) then
					loc_33_ = loc_30_;
				end
				rt_store_i32_into_i8(loc_22_, loc_31_, 0, loc_33_)
				loc_33_ = rt_load_i32_from_u8(loc_22_, loc_32_, 6);
				rt_store_i32_into_i8(loc_22_, bit32_or(loc_29_ + 1338, 0), 0, 106)
				rt_store_i32_into_i16(loc_22_, bit32_or(loc_29_ + 1336, 0), 0, 53850)
				loc_30_ = bit32_or(loc_29_ + 1339, 0);
				loc_31_ = -1;
				loc_27_ = 0;
				if not (rt_equal_i32(loc_33_, 35)) then
					loc_31_ = loc_27_;
				end
				rt_store_i32_into_i8(loc_22_, loc_30_, 0, loc_31_)
				loc_32_ = rt_load_i32_from_u8(loc_22_, loc_32_, 7);
				rt_store_i32_into_i8(loc_22_, bit32_or(loc_29_ + 1342, 0), 0, 106)
				rt_store_i32_into_i16(loc_22_, bit32_or(loc_29_ + 1340, 0), 0, 53850)
				loc_30_ = bit32_or(loc_29_ + 1343, 0);
				loc_27_ = -1;
				loc_31_ = 0;
				if not (rt_equal_i32(loc_32_, 35)) then
					loc_27_ = loc_31_;
				end
				rt_store_i32_into_i8(loc_22_, loc_30_, 0, loc_27_)
				loc_29_ = bit32_or(loc_29_ + 32, 0);
				loc_27_ = loc_29_;
				loc_28_ = bit32_or(loc_28_ + 4, 0);
			until not (rt_not_equal_i32(loc_29_, 256))
			loc_24_[1](1, 1312, 8, 8, loc_21_)
			loc_23_[1](1070, loc_21_)
			return loc_21_
		end), "->")
	end)(loc_105_, loc_106_, loc_107_, loc_108_, loc_100_);
	loc_102_ = { nil };
	loc_117_ = { nil };
	loc_122_ = { nil };
	loc_102_[1] = (function(loc_34_, loc_35_, loc_36_, loc_37_, loc_38_, loc_39_, loc_40_)
		return rt_function_type((function(loc_41_, loc_42_)
			local loc_43_, loc_44_, loc_45_, loc_46_, loc_47_, loc_48_, loc_49_, loc_50_, loc_51_, loc_52_, loc_53_, loc_54_, loc_55_, loc_56_, loc_57_, loc_58_, loc_59_, loc_60_, loc_61_, loc_62_, loc_63_
			loc_63_ = loc_39_[1];
			loc_44_ = loc_39_;
			loc_46_ = bit32_or(loc_63_ - 16, 0);
			loc_44_[1] = loc_46_;
			loc_45_ = loc_40_;
			loc_63_ = loc_42_;
			loc_59_ = loc_34_[1](1036, loc_63_)
			loc_60_ = loc_34_[1](1039, loc_63_)
			loc_43_ = loc_34_[1](1030, loc_63_)
			loc_61_ = buffer_read_i32(loc_45_[1], 0, 1276);
			loc_58_ = 0;
			loc_57_ = 0;
			loc_56_ = 0;
			loc_55_ = 0;
			loc_62_ = 2;
			loc_54_ = 0;
			if rt_not_equal_i32(loc_60_, 0) then
				loc_47_ = loc_34_;
				loc_48_ = loc_35_;
				loc_49_ = loc_36_;
				loc_50_ = loc_37_;
				loc_51_ = loc_38_;
				loc_53_ = loc_41_;
			else
				loc_47_ = loc_34_;
				loc_48_ = loc_35_;
				loc_49_ = loc_36_;
				loc_50_ = loc_37_;
				loc_51_ = loc_38_;
				loc_53_ = loc_41_;
				loc_62_ = loc_54_;
			end
			loc_54_ = rt_or_i32(loc_62_, (rt_not_equal_i32(loc_59_, 0) and 1 or 0));
			loc_62_ = 4;
			loc_52_ = 0;
			if not (rt_not_equal_i32(loc_43_, 0)) then
				loc_62_ = loc_52_;
			end
			loc_62_ = rt_or_i32(loc_54_, loc_62_);
			rt_store_i32(loc_45_, loc_55_, 1276, loc_62_)
			loc_62_ = rt_and_i32(loc_62_, rt_exclusive_or_i32(loc_61_, -1));
			loc_61_ = 0;
			if rt_greater_than_s32(loc_53_, 0) then
				loc_52_ = loc_53_;
			else
				loc_52_ = loc_53_;
				loc_55_ = loc_53_;
				loc_53_ = loc_61_;
			end
			loc_55_ = 50;
			if rt_less_than_s32(loc_53_, 50) then
				loc_61_ = loc_53_;
			else
				loc_54_ = loc_53_;
				loc_61_ = loc_53_;
				loc_53_ = loc_55_;
			end
			loc_55_ = buffer_read_i32(loc_45_[1], 0, 1272);
			if rt_equal_i32(loc_55_, 0) then
				loc_61_ = rt_multiply_i32(loc_53_, 46);
				if not (rt_equal_i32(loc_59_, 0)) then
					loc_59_ = buffer_read_i32(loc_45_[1], 0, 1268);
					rt_store_i32(loc_45_, 0, 1268, bit32_or(loc_59_ - loc_61_, 0))
				end
				if not (rt_equal_i32(loc_60_, 0)) then
					loc_60_ = buffer_read_i32(loc_45_[1], 0, 1268);
					rt_store_i32(loc_45_, 0, 1268, bit32_or(loc_60_ + loc_61_, 0))
				end
				loc_61_ = loc_48_[1](bit32_or(loc_46_ + 4, 0), loc_63_)
				if not (rt_equal_i32(loc_61_, 0)) then
					loc_61_ = loc_62_;
					loc_60_ = buffer_read_i32(loc_45_[1], loc_46_, 8);
					loc_62_ = buffer_read_i32(loc_45_[1], 0, 1232);
					if rt_less_than_s32(loc_62_, 0) then
						loc_59_ = 0;
					else
						if rt_equal_i32(loc_60_, loc_62_) then
							loc_59_ = 1;
						else
							rt_store_i32(loc_45_, 0, 1268, bit32_or(rt_shift_left_i32(loc_60_, 8) + -4608, 0))
							loc_59_ = 0;
						end
					end
					if not (rt_not_equal_i32(loc_59_, 0)) then
						loc_62_ = loc_60_;
					end
					rt_store_i32(loc_45_, 0, 1232, loc_62_)
					loc_62_ = buffer_read_i32(loc_45_[1], loc_46_, 12);
					loc_62_ = rt_or_i32(rt_shift_left_i32(loc_62_, 2), loc_61_);
				end
				loc_55_ = buffer_read_i32(loc_45_[1], 0, 1268);
				loc_61_ = 0;
				loc_60_ = 0;
				if not (rt_greater_than_s32(loc_55_, 0)) then
					loc_59_ = loc_55_;
					loc_55_ = loc_60_;
				end
				loc_60_ = 41984;
				if not (rt_less_than_s32(loc_55_, 41984)) then
					loc_59_ = loc_55_;
					loc_55_ = loc_60_;
				end
				rt_store_i32(loc_45_, loc_61_, 1268, loc_55_)
				loc_58_ = buffer_read_i32(loc_45_[1], 0, 1264);
				loc_43_ = buffer_read_i32(loc_45_[1], 0, 1284);
				loc_59_ = bit32_or(loc_43_ + -4608, 0);
				loc_61_ = rt_multiply_i32(loc_53_, 33);
				loc_56_ = bit32_or(loc_58_ - loc_61_, 0);
				loc_60_ = 0;
				loc_57_ = bit32_or(loc_58_ + loc_61_, 0);
				if rt_less_than_s32(loc_59_, loc_57_) then
					loc_58_ = loc_59_;
					loc_61_ = loc_56_;
				else
					loc_58_ = loc_59_;
					loc_61_ = loc_56_;
					loc_59_ = loc_57_;
				end
				if not (rt_less_than_s32(loc_58_, loc_61_)) then
					loc_58_ = loc_56_;
					loc_56_ = loc_59_;
				end
				loc_59_ = 0;
				if not (rt_greater_than_s32(loc_56_, 0)) then
					loc_58_ = loc_56_;
					loc_56_ = loc_59_;
				end
				loc_59_ = 41984;
				if not (rt_less_than_s32(loc_56_, 41984)) then
					loc_58_ = loc_56_;
					loc_56_ = loc_59_;
				end
				rt_store_i32(loc_45_, loc_60_, 1264, loc_56_)
				loc_60_ = rt_load_i32_from_u8(loc_45_, 0, 1296);
				if rt_equal_i32(loc_60_, 0) then
					loc_61_ = buffer_read_i32(loc_45_[1], 0, 1288);
					loc_62_ = buffer_read_i32(loc_45_[1], 0, 1280);
					loc_58_ = rt_divide_s32(loc_61_, 1000);
					loc_54_ = bit32_or(rt_multiply_i32(loc_58_, loc_53_) + loc_62_, 0);
					rt_store_i32(loc_45_, 0, 1280, loc_54_)
					loc_60_ = buffer_read_i32(loc_45_[1], 0, 1292);
					loc_59_ = rt_divide_s32(loc_60_, 1000);
					loc_62_ = bit32_or(rt_multiply_i32(loc_59_, loc_53_) + loc_43_, 0);
					rt_store_i32(loc_45_, 0, 1284, loc_62_)
					loc_57_ = 1024;
					if rt_less_than_s32(loc_62_, 1024) then
						loc_59_ = 0;
					else
						loc_59_ = loc_57_;
						loc_57_ = 50176;
						if rt_less_than_u32(loc_62_, 50177) then
							loc_59_ = 1;
						else
							loc_59_ = 0;
						end
					end
					if not (rt_not_equal_i32(loc_59_, 0)) then
						rt_store_i32(loc_45_, 0, 1284, loc_57_)
						rt_store_i32(loc_45_, 0, 1568, 440)
						rt_store_i32(loc_45_, 0, 1572, 551)
						rt_store_i32(loc_45_, 0, 1292, bit32_or(0 - loc_60_, 0))
						loc_62_ = loc_57_;
					end
					if rt_greater_than_s32(loc_61_, -1) then
						loc_60_ = 0;
					else
						if rt_greater_than_u32(bit32_or(loc_54_ + -3073, 0), 2559) then
							loc_60_ = 0;
						else
							if rt_less_than_s32(loc_62_, bit32_or(loc_55_ + -1024, 0)) then
								loc_60_ = 1;
							else
								if rt_greater_than_u32(loc_62_, bit32_or(loc_55_ + 10240, 0)) then
									loc_60_ = 1;
								else
									rt_store_i32(loc_45_, 0, 1280, 5632)
									rt_store_i32(loc_45_, 0, 1568, 660)
									rt_store_i32(loc_45_, 0, 1572, 882)
									loc_60_ = bit32_or(0 - loc_61_, 0);
									loc_59_ = 0;
									loc_58_ = 78848;
									if rt_less_than_u32(loc_60_, 78848) then
										loc_61_ = loc_60_;
									else
										loc_61_ = loc_60_;
										loc_60_ = loc_58_;
									end
									rt_store_i32(loc_45_, loc_59_, 1288, bit32_or(loc_60_ + 3072, 0))
									loc_59_ = rt_divide_s32(bit32_or(bit32_or(loc_62_ - loc_55_, 0) + -4608, 0), 18);
									rt_store_i32(loc_45_, 0, 1292, rt_multiply_i32(loc_59_, 180))
									loc_60_ = 1;
								end
							end
						end
					end
					if not (rt_not_equal_i32(loc_60_, 0)) then
						if rt_less_than_s32(loc_61_, 1) then
							loc_62_ = 0;
						else
							if rt_greater_than_u32(bit32_or(loc_54_ + -76288, 0), 2559) then
								loc_62_ = 0;
							else
								if rt_less_than_s32(loc_62_, bit32_or(loc_56_ + -1024, 0)) then
									loc_62_ = 1;
								else
									if rt_greater_than_u32(loc_62_, bit32_or(loc_56_ + 10240, 0)) then
										loc_62_ = 1;
									else
										rt_store_i32(loc_45_, 0, 1280, 76288)
										rt_store_i32(loc_45_, 0, 1568, 660)
										rt_store_i32(loc_45_, 0, 1572, 882)
										loc_59_ = 0;
										loc_60_ = -3072;
										loc_58_ = 78848;
										if not (rt_less_than_u32(loc_61_, 78848)) then
											loc_61_ = loc_58_;
										end
										rt_store_i32(loc_45_, loc_59_, 1288, bit32_or(loc_60_ - loc_61_, 0))
										loc_61_ = rt_divide_s32(bit32_or(bit32_or(loc_62_ - loc_56_, 0) + -4608, 0), 18);
										rt_store_i32(loc_45_, 0, 1292, rt_multiply_i32(loc_61_, 180))
										loc_62_ = 1;
									end
								end
							end
						end
						if not (rt_not_equal_i32(loc_62_, 0)) then
							if rt_greater_than_s32(loc_54_, -1025) then
								if not (rt_less_than_s32(loc_54_, 82945)) then
									rt_store_i32(loc_45_, 0, 1572, 4410)
									rt_store_i32(loc_45_, 0, 1568, 880)
									loc_62_ = buffer_read_i32(loc_45_[1], 0, 1256);
									rt_store_i32(loc_45_, 0, 1256, bit32_or(loc_62_ + 1, 0))
									if not (rt_less_than_s32(loc_62_, 8)) then
										rt_store_i32(loc_45_, 0, 1272, 1)
									end
									rt_store_i32(loc_45_, 0, 1284, 25600)
									rt_store_i32(loc_45_, 0, 1280, 40960)
									rt_store_i32_into_i8(loc_45_, 0, 1296, 1)
									rt_store_i32(loc_45_, 0, 1300, 1)
									rt_store_i32(loc_45_, 0, 1288, 0)
									rt_store_i32(loc_45_, 0, 1292, 0)
								end
							else
								rt_store_i32(loc_45_, 0, 1572, 4410)
								rt_store_i32(loc_45_, 0, 1568, 220)
								loc_62_ = buffer_read_i32(loc_45_[1], 0, 1260);
								rt_store_i32(loc_45_, 0, 1260, bit32_or(loc_62_ + 1, 0))
								if not (rt_less_than_s32(loc_62_, 8)) then
									rt_store_i32(loc_45_, 0, 1272, 2)
								end
								rt_store_i32(loc_45_, 0, 1284, 25600)
								rt_store_i32(loc_45_, 0, 1280, 40960)
								rt_store_i32_into_i8(loc_45_, 0, 1296, 1)
								rt_store_i32(loc_45_, 0, 1300, -1)
								rt_store_i32(loc_45_, 0, 1288, 0)
								rt_store_i32(loc_45_, 0, 1292, 0)
							end
						end
					end
				else
					loc_60_ = loc_62_;
					loc_62_ = buffer_read_i32(loc_45_[1], 0, 1300);
					if rt_not_equal_i32(rt_and_i32(loc_60_, 4), 0) then
						loc_54_ = loc_61_;
						loc_57_ = loc_60_;
						loc_61_ = 0;
					else
						loc_54_ = loc_61_;
						loc_57_ = loc_60_;
						if rt_greater_than_s32(loc_62_, -1) then
							loc_61_ = 1;
						else
							loc_61_ = 0;
						end
					end
					if not (rt_not_equal_i32(loc_61_, 0)) then
						rt_store_i32(loc_45_, 0, 1288, rt_multiply_i32(loc_62_, 38400))
						loc_62_ = buffer_read_i32(loc_45_[1], 0, 1228);
						loc_62_ = bit32_or(rt_multiply_i32(loc_62_, 1103515245) + 12345, 0);
						rt_store_i32(loc_45_, 0, 1228, loc_62_)
						loc_62_ = rt_remainder_u32(rt_and_i32(rt_shift_right_u32(loc_62_, 16), 32767), 161);
						rt_store_i32(loc_45_, 0, 1292, bit32_or(rt_shift_left_i32(loc_62_, 8) + -20480, 0))
						rt_store_i32_into_i8(loc_45_, 0, 1296, 0)
					end
				end
			else
				loc_59_, loc_60_ = loc_60_, loc_59_;
				if rt_less_than_u32(loc_62_, 4) then
					loc_43_ = loc_56_;
					loc_54_ = loc_57_;
					loc_55_ = loc_58_;
					loc_56_ = loc_61_;
					loc_57_ = loc_62_;
				else
					loc_43_ = loc_56_;
					loc_54_ = loc_57_;
					loc_55_ = loc_58_;
					loc_56_ = loc_61_;
					loc_57_ = loc_62_;
					rt_store_i32(loc_45_, 0, 1264, 20992)
					rt_store_i32(loc_45_, 0, 1268, 20992)
					rt_store_i32(loc_45_, 0, 1280, 40960)
					rt_store_i32(loc_45_, 0, 1284, 25600)
					rt_store_i32_into_i8(loc_45_, 0, 1296, 1)
					loc_62_ = buffer_read_i32(loc_45_[1], 0, 1228);
					loc_59_ = bit32_or(rt_multiply_i32(rt_exclusive_or_i32(rt_and_i32(rt_shift_right_u32(bit32_or(rt_multiply_i32(loc_62_, 1103515245) + 12345, 0), 16), 32767), -1640531527), 1103515245) + 12345, 0);
					rt_store_i32(loc_45_, 0, 1228, loc_59_)
					loc_61_ = 0;
					loc_62_ = 1;
					loc_60_ = -1;
					if not (rt_not_equal_i32(rt_and_i32(loc_59_, 65536), 0)) then
						loc_62_ = loc_60_;
					end
					rt_store_i32(loc_45_, loc_61_, 1300, loc_62_)
					rt_store_i32(loc_45_, 0, 1260, 0)
					rt_store_i32(loc_45_, 0, 1256, 0)
					rt_store_i32(loc_45_, 0, 1272, 0)
					rt_store_i32(loc_45_, 0, 1276, 0)
					rt_store_i32(loc_45_, 0, 1288, 0)
					rt_store_i32(loc_45_, 0, 1292, 0)
				end
			end
			rt_store_i64(loc_45_, 0, 1588, into_bits_i64(0, 0))
			rt_store_i32(loc_45_, 0, 1584, 4)
			rt_store_i32(loc_45_, 0, 1576, 1)
			rt_store_i64(loc_45_, 0, 1596, into_bits_i64(0, 0))
			rt_store_i32(loc_45_, 0, 1604, 1053720)
			loc_62_ = 1;
			loc_59_ = 16;
			repeat
				loc_60_ = loc_56_;
				loc_61_ = loc_57_;
				loc_56_ = bit32_or(loc_59_ + -12, 0);
				if rt_less_than_equal_s32(loc_62_, 255) then
					loc_57_ = bit32_or(loc_62_ + 1, 0);
					rt_store_i32(loc_45_, 0, 1576, loc_57_)
					loc_62_ = rt_multiply_i32(loc_62_, 24);
					rt_store_i32(loc_45_, bit32_or(loc_62_ + 1604, 0), 0, 3817544)
					rt_store_i64(loc_45_, bit32_or(loc_62_ + 1596, 0), 0, into_bits_i64(2, 6))
					rt_store_i32(loc_45_, bit32_or(loc_62_ + 1592, 0), 0, loc_56_)
					rt_store_i64(loc_45_, bit32_or(loc_62_ + 1584, 0), 0, into_bits_i64(1, 159))
				else
					loc_61_ = loc_62_;
					loc_62_ = loc_61_;
					loc_57_ = loc_61_;
				end
				if rt_greater_than_u32(loc_56_, 187) then
					loc_61_ = 0;
				else
					if rt_less_than_equal_s32(loc_57_, 255) then
						loc_60_ = loc_59_;
						loc_61_ = loc_57_;
						loc_62_ = bit32_or(loc_61_ + 1, 0);
						rt_store_i32(loc_45_, 0, 1576, loc_62_)
						loc_57_ = rt_multiply_i32(loc_61_, 24);
						rt_store_i32(loc_45_, bit32_or(loc_57_ + 1604, 0), 0, 3817544)
						rt_store_i64(loc_45_, bit32_or(loc_57_ + 1596, 0), 0, into_bits_i64(2, 6))
						rt_store_i32(loc_45_, bit32_or(loc_57_ + 1592, 0), 0, loc_60_)
						rt_store_i64(loc_45_, bit32_or(loc_57_ + 1584, 0), 0, into_bits_i64(1, 159))
						loc_61_ = 1;
						loc_59_ = bit32_or(loc_60_ + 24, 0);
					else
						loc_60_ = loc_57_;
						loc_61_ = 1;
						loc_62_ = loc_60_;
						loc_59_ = bit32_or(loc_59_ + 24, 0);
						loc_57_ = loc_60_;
					end
				end
			until loc_61_ == 0
			loc_62_ = buffer_read_i32(loc_45_[1], 0, 1256);
			loc_51_[1](126, loc_62_, loc_63_)
			loc_62_ = buffer_read_i32(loc_45_[1], 0, 1260);
			loc_51_[1](182, loc_62_, loc_63_)
			loc_58_ = buffer_read_i32(loc_45_[1], 0, 1576);
			if rt_greater_than_s32(loc_58_, 255) then
				loc_63_ = 0;
			else
				loc_61_ = loc_56_;
				loc_62_ = loc_57_;
				loc_63_ = loc_59_;
				loc_56_ = bit32_or(loc_58_ + 1, 0);
				rt_store_i32(loc_45_, 0, 1576, loc_56_)
				loc_57_ = rt_multiply_i32(loc_58_, 24);
				rt_store_i32(loc_45_, bit32_or(loc_57_ + 1604, 0), 0, 15263976)
				rt_store_i64(loc_45_, bit32_or(loc_57_ + 1596, 0), 0, into_bits_i64(6, 36))
				loc_63_ = buffer_read_i32(loc_45_[1], 0, 1268);
				loc_63_ = rt_divide_s32(loc_63_, 256);
				rt_store_i32(loc_45_, bit32_or(loc_57_ + 1592, 0), 0, loc_63_)
				rt_store_i64(loc_45_, bit32_or(loc_57_ + 1584, 0), 0, into_bits_i64(1, 12))
				loc_59_ = 256;
				if rt_equal_i32(loc_58_, 255) then
					loc_63_ = 1;
				else
					loc_63_ = loc_59_;
					loc_58_ = bit32_or(loc_58_ + 2, 0);
					rt_store_i32(loc_45_, 0, 1576, loc_58_)
					loc_59_ = rt_multiply_i32(loc_56_, 24);
					rt_store_i32(loc_45_, bit32_or(loc_59_ + 1604, 0), 0, 15263976)
					rt_store_i64(loc_45_, bit32_or(loc_59_ + 1596, 0), 0, into_bits_i64(6, 36))
					loc_63_ = buffer_read_i32(loc_45_[1], 0, 1264);
					loc_62_ = rt_divide_s32(loc_63_, 256);
					rt_store_i32(loc_45_, bit32_or(loc_59_ + 1592, 0), 0, loc_62_)
					rt_store_i64(loc_45_, bit32_or(loc_59_ + 1584, 0), 0, into_bits_i64(1, 302))
					loc_63_ = 0;
				end
			end
			if not (rt_not_equal_i32(loc_63_, 0)) then
				loc_63_ = loc_59_;
				loc_63_ = buffer_read_i32(loc_45_[1], 0, 1272);
				if rt_not_equal_i32(loc_63_, 0) then
					loc_59_ = loc_54_;
					loc_61_ = loc_56_;
					loc_62_ = loc_57_;
					if rt_less_than_equal_s32(loc_58_, 255) then
						loc_56_ = bit32_or(loc_58_ + 1, 0);
						rt_store_i32(loc_45_, 0, 1576, loc_56_)
						loc_57_ = rt_multiply_i32(loc_58_, 24);
						rt_store_i64(loc_45_, bit32_or(loc_57_ + 1600, 0), 0, into_bits_i64(6, 5952106))
						rt_store_i64(loc_45_, bit32_or(loc_57_ + 1592, 0), 0, into_bits_i64(194, 160))
						loc_54_ = (rt_equal_i32(loc_63_, 1) and 1 or 0);
						loc_62_ = bit32_or(loc_57_ + 1588, 0);
						loc_63_ = 0;
						loc_61_ = 160;
						if not (rt_not_equal_i32(loc_54_, 0)) then
							loc_63_ = loc_61_;
						end
						rt_store_i32(loc_45_, loc_62_, 0, loc_63_)
						rt_store_i32(loc_45_, bit32_or(loc_57_ + 1584, 0), 0, 1)
						loc_59_ = 256;
						if rt_equal_i32(loc_58_, 255) then
							loc_61_ = 2;
						else
							loc_63_ = loc_57_;
							loc_57_ = bit32_or(loc_58_ + 2, 0);
							rt_store_i32(loc_45_, 0, 1576, loc_57_)
							loc_56_ = rt_multiply_i32(loc_56_, 24);
							rt_store_i64(loc_45_, bit32_or(loc_56_ + 1600, 0), 0, into_bits_i64(2, 5952106))
							loc_62_ = bit32_or(loc_56_ + 1596, 0);
							loc_61_ = 1117;
							loc_63_ = 1108;
							if not (rt_not_equal_i32(loc_54_, 0)) then
								loc_61_ = loc_63_;
							end
							rt_store_i32(loc_45_, loc_62_, 0, loc_61_)
							rt_store_i32(loc_45_, bit32_or(loc_56_ + 1592, 0), 0, 80)
							rt_store_i64(loc_45_, bit32_or(loc_56_ + 1584, 0), 0, into_bits_i64(6, 112))
							if rt_greater_than_s32(loc_58_, 253) then
								loc_61_ = 2;
							else
								loc_61_ = loc_56_;
								loc_56_ = loc_55_;
								loc_55_ = loc_54_;
								loc_54_ = loc_43_;
								loc_61_ = 0;
								loc_58_ = bit32_or(loc_58_ + 3, 0);
								loc_56_ = 15263976;
								loc_55_ = 1044;
								loc_54_ = 1;
								loc_43_ = 104;
							end
						end
					else
						loc_57_ = loc_62_;
						loc_62_ = loc_61_;
						loc_61_ = loc_63_;
						loc_63_ = loc_59_;
						loc_59_ = loc_58_;
						loc_61_ = 2;
						loc_58_ = loc_59_;
						loc_56_ = loc_62_;
						loc_54_ = loc_63_;
					end
				else
					loc_59_ = loc_57_;
					loc_61_ = loc_56_;
					loc_62_ = loc_63_;
					loc_63_ = loc_54_;
					loc_59_ = rt_load_i32_from_u8(loc_45_, 0, 1296);
					if rt_less_than_equal_s32(loc_58_, 255) then
						loc_56_ = loc_43_;
						loc_62_ = loc_61_;
						loc_61_ = loc_55_;
						loc_58_, loc_63_ = loc_63_, loc_58_;
						loc_57_ = bit32_or(loc_63_ + 1, 0);
						rt_store_i32(loc_45_, 0, 1576, loc_57_)
						loc_63_ = rt_multiply_i32(loc_63_, 24);
						loc_54_ = bit32_or(loc_63_ + 1604, 0);
						loc_55_ = 5952106;
						loc_43_ = 15263976;
						if not (rt_not_equal_i32(rt_and_i32(loc_59_, 1), 0)) then
							loc_55_ = loc_43_;
						end
						rt_store_i32(loc_45_, loc_54_, 0, loc_55_)
						rt_store_i64(loc_45_, bit32_or(loc_63_ + 1596, 0), 0, into_bits_i64(4, 0))
						loc_55_ = buffer_read_i32(loc_45_[1], 0, 1284);
						loc_54_ = rt_divide_s32(loc_55_, 256);
						rt_store_i32(loc_45_, bit32_or(loc_63_ + 1592, 0), 0, loc_54_)
						loc_55_ = buffer_read_i32(loc_45_[1], 0, 1280);
						loc_55_ = rt_divide_s32(loc_55_, 256);
						rt_store_i32(loc_45_, bit32_or(loc_63_ + 1588, 0), 0, loc_55_)
						rt_store_i32(loc_45_, bit32_or(loc_63_ + 1584, 0), 0, 2)
					else
						loc_56_ = loc_43_;
						loc_57_ = loc_58_;
						loc_58_ = loc_63_;
						loc_62_ = loc_61_;
						loc_61_ = loc_55_;
						loc_63_ = loc_57_;
					end
					loc_55_ = buffer_read_i32(loc_45_[1], 0, 1300);
					if rt_equal_i32(rt_and_i32(loc_59_, (rt_greater_than_s32(loc_55_, 0) and 1 or 0)), 1) then
						if rt_less_than_equal_s32(loc_57_, 255) then
							loc_61_ = 0;
							loc_58_ = bit32_or(loc_57_ + 1, 0);
							loc_56_ = 5952106;
							loc_55_ = 1024;
							loc_54_ = 2;
							loc_43_ = 170;
						else
							loc_55_ = loc_61_;
							loc_61_ = loc_59_;
							loc_59_ = loc_63_;
							loc_63_ = loc_56_;
							loc_56_ = loc_62_;
							loc_62_ = loc_58_;
							loc_61_ = 2;
							loc_58_ = loc_59_;
							loc_59_ = loc_57_;
							loc_54_ = loc_62_;
							loc_43_ = loc_63_;
						end
					else
						loc_55_ = loc_61_;
						loc_61_ = loc_63_;
						loc_63_ = loc_56_;
						loc_56_ = loc_62_;
						loc_62_ = loc_58_;
						loc_61_ = 1;
						loc_58_ = loc_57_;
						loc_54_ = loc_62_;
						loc_43_ = loc_63_;
					end
				end
				if (loc_61_) >= 0 and (loc_61_) < 2 then
					if (loc_61_) < 1 then
						rt_store_i32(loc_45_, 0, 1576, loc_58_)
						loc_59_ = rt_multiply_i32(loc_57_, 24);
						rt_store_i32(loc_45_, bit32_or(loc_59_ + 1604, 0), 0, loc_56_)
						rt_store_i32(loc_45_, bit32_or(loc_59_ + 1600, 0), 0, loc_54_)
						rt_store_i32(loc_45_, bit32_or(loc_59_ + 1596, 0), 0, loc_55_)
						rt_store_i32(loc_45_, bit32_or(loc_59_ + 1592, 0), 0, loc_43_)
						rt_store_i64(loc_45_, bit32_or(loc_59_ + 1584, 0), 0, into_bits_i64(6, 94))
						loc_57_ = 0;
					else
						loc_57_ = 0;
					end
				else
					loc_57_ = 1;
				end
				if not (rt_not_equal_i32(loc_57_, 0)) then
					if rt_less_than_equal_s32(loc_58_, 255) then
						loc_57_ = bit32_or(loc_58_ + 1, 0);
						rt_store_i32(loc_45_, 0, 1576, loc_57_)
						loc_59_ = rt_multiply_i32(loc_58_, 24);
						rt_store_i64(loc_45_, bit32_or(loc_59_ + 1600, 0), 0, into_bits_i64(1, 3817544))
						rt_store_i32(loc_45_, bit32_or(loc_59_ + 1596, 0), 0, 1058)
						rt_store_i32(loc_45_, bit32_or(loc_59_ + 1592, 0), 0, 190)
						rt_store_i64(loc_45_, bit32_or(loc_59_ + 1584, 0), 0, into_bits_i64(6, 4))
						loc_59_ = 256;
						if not (rt_equal_i32(loc_58_, 255)) then
							loc_59_ = bit32_or(loc_58_ + 2, 0);
							rt_store_i32(loc_45_, 0, 1576, loc_59_)
							loc_58_ = rt_multiply_i32(loc_57_, 24);
							rt_store_i64(loc_45_, bit32_or(loc_58_ + 1600, 0), 0, into_bits_i64(1, 0))
							rt_store_i64(loc_45_, bit32_or(loc_58_ + 1592, 0), 0, into_bits_i64(188, 1))
							rt_store_i64(loc_45_, bit32_or(loc_58_ + 1584, 0), 0, into_bits_i64(5, 308))
						end
					else
						loc_59_ = loc_58_;
					end
				end
			end
			loc_49_[1](1584, loc_59_, loc_60_)
			loc_60_ = buffer_read_i32(loc_45_[1], 0, 1252);
			if not (rt_equal_i32(loc_60_, 0)) then
				loc_53_ = rt_divide_u32(rt_multiply_i32(loc_53_, 22050), 1000);
				loc_60_ = loc_53_;
				if not (rt_less_than_s32(loc_52_, 1)) then
					loc_60_ = 2205;
					if rt_less_than_u32(loc_53_, 2205) then
						loc_59_ = loc_53_;
						loc_53_ = loc_43_;
						loc_43_ = loc_50_;
					else
						loc_59_ = loc_53_;
						loc_53_ = loc_43_;
						loc_43_ = loc_50_;
						loc_59_ = loc_60_;
					end
					loc_60_ = 1;
					if rt_greater_than_u32(loc_59_, 1) then
						loc_52_ = loc_59_;
					else
						loc_52_ = loc_59_;
						loc_59_ = loc_60_;
					end
					loc_60_ = buffer_read_i32(loc_45_[1], 0, 1568);
					loc_54_ = buffer_read_i32(loc_45_[1], 0, 1572);
					loc_56_ = buffer_read_i32(loc_45_[1], 0, 7728);
					loc_60_ = rt_divide_u32(rt_shift_left_i32(loc_60_, 16), 22050);
					loc_50_ = loc_60_;
					loc_55_ = 0;
					loc_58_ = rt_and_i32(rt_shift_left_i32(loc_59_, 1), 16777212);
					loc_57_ = rt_and_i32(loc_59_, 1);
					repeat
						if rt_greater_than_equal_s32(loc_54_, 1) then
							loc_59_ = loc_55_;
							loc_60_ = loc_58_;
							loc_58_ = loc_56_;
							loc_56_ = loc_54_;
							loc_56_ = bit32_or(loc_56_ + -1, 0);
							rt_store_i32(loc_45_, 0, 1572, loc_56_)
							loc_58_ = bit32_or(loc_58_ + loc_50_, 0);
							rt_store_i32(loc_45_, 0, 7728, loc_58_)
							loc_55_ = 3000;
							loc_54_ = -3000;
							if not (rt_not_equal_i32(rt_and_i32(loc_58_, 32768), 0)) then
								loc_55_ = loc_54_;
							end
						else
							loc_59_ = loc_55_;
							loc_60_ = loc_58_;
							loc_58_ = loc_56_;
							loc_56_ = loc_54_;
							loc_55_ = 0;
						end
						rt_store_i32_into_i16(loc_45_, bit32_or(loc_59_ + 7744, 0), 0, loc_55_)
						if rt_greater_than_equal_s32(loc_56_, 1) then
							loc_54_ = bit32_or(loc_56_ + -1, 0);
							rt_store_i32(loc_45_, 0, 1572, loc_54_)
							loc_56_ = bit32_or(loc_58_ + loc_50_, 0);
							rt_store_i32(loc_45_, 0, 7728, loc_56_)
							loc_58_ = 3000;
							loc_55_ = -3000;
							if not (rt_not_equal_i32(rt_and_i32(loc_56_, 32768), 0)) then
								loc_58_ = loc_55_;
							end
						else
							loc_54_ = loc_56_;
							loc_56_ = loc_58_;
							loc_58_ = 0;
						end
						rt_store_i32_into_i16(loc_45_, bit32_or(loc_59_ + 7746, 0), 0, loc_58_)
						loc_59_ = bit32_or(loc_59_ + 4, 0);
						loc_55_ = loc_59_;
						loc_58_ = loc_60_;
					until not (rt_not_equal_i32(loc_60_, loc_59_))
					if not (rt_equal_i32(loc_57_, 0)) then
						if rt_greater_than_equal_s32(loc_54_, 1) then
							loc_50_, loc_54_ = loc_54_, loc_50_;
							loc_55_, loc_56_ = loc_56_, loc_55_;
							rt_store_i32(loc_45_, 0, 1572, bit32_or(loc_50_ + -1, 0))
							loc_50_ = bit32_or(loc_55_ + loc_54_, 0);
							rt_store_i32(loc_45_, 0, 7728, loc_50_)
							loc_55_ = 3000;
							loc_54_ = -3000;
							if not (rt_not_equal_i32(rt_and_i32(loc_50_, 32768), 0)) then
								loc_55_ = loc_54_;
							end
						else
							loc_50_, loc_56_ = loc_56_, loc_50_;
							loc_56_, loc_55_ = loc_55_, loc_56_;
							loc_55_ = 0;
						end
						rt_store_i32_into_i16(loc_45_, bit32_or(loc_56_ + 7744, 0), 0, loc_55_)
					end
					loc_50_ = loc_43_;
					loc_43_[1](7744, loc_52_, loc_53_)
				end
			end
			loc_44_[1] = bit32_or(loc_46_ + 16, 0);
			return loc_43_
		end), "i32->")
	end)(loc_109_, loc_110_, loc_111_, loc_112_, loc_117_, loc_122_, loc_100_);
	loc_117_[1] = (function(loc_64_)
		return rt_function_type((function(loc_65_, loc_66_, loc_67_)
			local loc_68_, loc_69_, loc_70_, loc_71_, loc_72_
			loc_72_ = rt_remainder_s32(loc_66_, 10);
			loc_71_ = rt_load_i32_from_u8(loc_64_, bit32_or(loc_72_ + 1216, 0), 0);
			loc_69_ = loc_64_;
			loc_68_ = loc_67_;
			if rt_equal_i32(rt_and_i32(loc_71_, 1), 0) then
				loc_70_ = loc_65_;
			else
				loc_70_ = loc_65_;
				loc_72_ = buffer_read_i32(loc_69_[1], 0, 1576);
				if not (rt_greater_than_s32(loc_72_, 255)) then
					rt_store_i32(loc_69_, 0, 1576, bit32_or(loc_72_ + 1, 0))
					loc_72_ = rt_multiply_i32(loc_72_, 24);
					rt_store_i64(loc_69_, bit32_or(loc_72_ + 1600, 0), 0, into_bits_i64(3, 15263976))
					rt_store_i64(loc_69_, bit32_or(loc_72_ + 1592, 0), 0, into_bits_i64(10, 12))
					rt_store_i32(loc_69_, bit32_or(loc_72_ + 1588, 0), 0, loc_70_)
					rt_store_i32(loc_69_, bit32_or(loc_72_ + 1584, 0), 0, 1)
				end
			end
			if not (rt_equal_i32(rt_and_i32(loc_71_, 2), 0)) then
				loc_72_ = buffer_read_i32(loc_69_[1], 0, 1576);
				if not (rt_greater_than_s32(loc_72_, 255)) then
					rt_store_i32(loc_69_, 0, 1576, bit32_or(loc_72_ + 1, 0))
					loc_72_ = rt_multiply_i32(loc_72_, 24);
					rt_store_i64(loc_69_, bit32_or(loc_72_ + 1600, 0), 0, into_bits_i64(10, 15263976))
					rt_store_i64(loc_69_, bit32_or(loc_72_ + 1592, 0), 0, into_bits_i64(10, 3))
					rt_store_i32(loc_69_, bit32_or(loc_72_ + 1588, 0), 0, bit32_or(loc_70_ + 9, 0))
					rt_store_i32(loc_69_, bit32_or(loc_72_ + 1584, 0), 0, 1)
				end
			end
			if not (rt_equal_i32(rt_and_i32(loc_71_, 4), 0)) then
				loc_72_ = buffer_read_i32(loc_69_[1], 0, 1576);
				if not (rt_greater_than_s32(loc_72_, 255)) then
					rt_store_i32(loc_69_, 0, 1576, bit32_or(loc_72_ + 1, 0))
					loc_72_ = rt_multiply_i32(loc_72_, 24);
					rt_store_i64(loc_69_, bit32_or(loc_72_ + 1600, 0), 0, into_bits_i64(10, 15263976))
					rt_store_i64(loc_69_, bit32_or(loc_72_ + 1592, 0), 0, into_bits_i64(20, 3))
					rt_store_i32(loc_69_, bit32_or(loc_72_ + 1588, 0), 0, bit32_or(loc_70_ + 9, 0))
					rt_store_i32(loc_69_, bit32_or(loc_72_ + 1584, 0), 0, 1)
				end
			end
			if not (rt_equal_i32(rt_and_i32(loc_71_, 8), 0)) then
				loc_72_ = buffer_read_i32(loc_69_[1], 0, 1576);
				if not (rt_greater_than_s32(loc_72_, 255)) then
					rt_store_i32(loc_69_, 0, 1576, bit32_or(loc_72_ + 1, 0))
					loc_72_ = rt_multiply_i32(loc_72_, 24);
					rt_store_i64(loc_69_, bit32_or(loc_72_ + 1600, 0), 0, into_bits_i64(3, 15263976))
					rt_store_i64(loc_69_, bit32_or(loc_72_ + 1592, 0), 0, into_bits_i64(27, 12))
					rt_store_i32(loc_69_, bit32_or(loc_72_ + 1588, 0), 0, loc_70_)
					rt_store_i32(loc_69_, bit32_or(loc_72_ + 1584, 0), 0, 1)
				end
			end
			if not (rt_equal_i32(rt_and_i32(loc_71_, 16), 0)) then
				loc_72_ = buffer_read_i32(loc_69_[1], 0, 1576);
				if not (rt_greater_than_s32(loc_72_, 255)) then
					rt_store_i32(loc_69_, 0, 1576, bit32_or(loc_72_ + 1, 0))
					loc_72_ = rt_multiply_i32(loc_72_, 24);
					rt_store_i64(loc_69_, bit32_or(loc_72_ + 1600, 0), 0, into_bits_i64(10, 15263976))
					rt_store_i64(loc_69_, bit32_or(loc_72_ + 1592, 0), 0, into_bits_i64(20, 3))
					rt_store_i32(loc_69_, bit32_or(loc_72_ + 1588, 0), 0, loc_70_)
					rt_store_i32(loc_69_, bit32_or(loc_72_ + 1584, 0), 0, 1)
				end
			end
			if not (rt_equal_i32(rt_and_i32(loc_71_, 32), 0)) then
				loc_72_ = buffer_read_i32(loc_69_[1], 0, 1576);
				if not (rt_greater_than_s32(loc_72_, 255)) then
					rt_store_i32(loc_69_, 0, 1576, bit32_or(loc_72_ + 1, 0))
					loc_72_ = rt_multiply_i32(loc_72_, 24);
					rt_store_i64(loc_69_, bit32_or(loc_72_ + 1600, 0), 0, into_bits_i64(10, 15263976))
					rt_store_i64(loc_69_, bit32_or(loc_72_ + 1592, 0), 0, into_bits_i64(10, 3))
					rt_store_i32(loc_69_, bit32_or(loc_72_ + 1588, 0), 0, loc_70_)
					rt_store_i32(loc_69_, bit32_or(loc_72_ + 1584, 0), 0, 1)
				end
			end
			if not (rt_equal_i32(rt_and_i32(loc_71_, 64), 0)) then
				loc_71_ = buffer_read_i32(loc_69_[1], 0, 1576);
				if not (rt_greater_than_s32(loc_71_, 255)) then
					rt_store_i32(loc_69_, 0, 1576, bit32_or(loc_71_ + 1, 0))
					loc_71_ = rt_multiply_i32(loc_71_, 24);
					rt_store_i64(loc_69_, bit32_or(loc_71_ + 1600, 0), 0, into_bits_i64(3, 15263976))
					rt_store_i64(loc_69_, bit32_or(loc_71_ + 1592, 0), 0, into_bits_i64(19, 12))
					rt_store_i32(loc_69_, bit32_or(loc_71_ + 1588, 0), 0, loc_70_)
					rt_store_i32(loc_69_, bit32_or(loc_71_ + 1584, 0), 0, 1)
				end
			end
			return loc_68_
		end), "i32,i32->")
	end)(loc_100_);
	loc_101_ = { nil };
	loc_101_[1] = (function(loc_73_)
		return rt_function_type((function(loc_74_)
			local loc_75_, loc_76_, loc_77_, loc_78_
			loc_77_ = buffer_read_i32(loc_73_[1], 0, 1256);
			loc_78_ = loc_73_;
			loc_76_ = buffer_read_i32(loc_78_[1], 0, 1260);
			loc_75_ = loc_74_;
			return bit32_or(rt_multiply_i32(loc_77_, 100) + loc_76_, 0), loc_75_
		end), "->i32")
	end)(loc_100_);
	loc_119_[1] = (function(loc_79_, loc_80_)
		return rt_function_type((function(loc_81_)
			local loc_82_, loc_83_, loc_84_, loc_85_, loc_86_, loc_87_, loc_88_
			rt_store_i32(loc_80_, 0, 12160, 12160)
			loc_84_ = loc_80_;
			loc_88_ = 77808;
			if rt_equal_i32(77808, 0) then
				loc_82_ = loc_81_;
				loc_83_ = loc_79_;
				loc_88_ = loc_83_[1];
				loc_88_ = (rt_greater_than_u32(loc_88_, 1024) and 1 or 0);
				loc_85_ = bit32_or(77808 - 12268, 0);
				loc_87_ = 1024;
				if not (rt_not_equal_i32(loc_88_, 0)) then
					loc_86_ = loc_85_;
					loc_85_ = loc_87_;
				end
				loc_87_ = 77808;
				loc_86_ = 1024;
				if not (rt_not_equal_i32(loc_88_, 0)) then
					loc_87_ = loc_86_;
				end
			else
				loc_82_ = loc_81_;
				loc_83_ = loc_79_;
				loc_87_ = loc_88_;
				loc_85_ = bit32_or(77808 - 12272, 0);
			end
			rt_store_i32(loc_84_, 56, 12160, 0)
			rt_store_i32(loc_84_, 52, 12160, loc_85_)
			rt_store_i32(loc_84_, 48, 12160, loc_87_)
			rt_store_i32(loc_84_, 8, 12160, 12160)
			rt_store_i32(loc_84_, 4, 12160, 12160)
			loc_87_ = buffer_read_i32(loc_84_[1], 0, 12156);
			rt_store_i32(loc_84_, 12, 12160, loc_87_)
			loc_86_ = 0;
			loc_87_ = 8388608;
			if not (rt_less_than_u32(loc_85_, 8388608)) then
				loc_85_ = loc_87_;
			end
			rt_store_i32(loc_84_, loc_86_, 1236, loc_85_)
			return loc_82_
		end), "->")
	end)(loc_122_, loc_100_);
	loc_120_ = rt_table_new({ }, 1, 1);
	loc_124_ = rt_memory_new({ [0] = "press enter\x00up\x00down\x00enter - again\x00wasmrt pong\x00pong: up/down - paddle, enter - serve\x00CPU WINS\x00YOU WIN\x00..####..\x00.#....#.\x00#......#\x00#..##..#\x00#.#..#.#\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00e\x04\x00\x00n\x04\x00\x00\x89\x04\x00\x00w\x04\x00\x00\x89\x04\x00\x00\x80\x04\x00\x00n\x04\x00\x00e\x04\x00\x00?\x06[Ofm}\x07\x7fo", }, 202, 202);
	rt_memory_copy(loc_100_, (function(loc_89_)
		local loc_90_
		loc_90_ = loc_89_;
		return 1024, loc_90_
	end)(), loc_124_, 0, 202)
	loc_125_ = rt_memory_new({ [0] = "90\x00\x00\xff\xff\xff\xff\x00\x00\x02\x00", }, 12, 12);
	rt_memory_copy(loc_100_, (function(loc_91_)
		local loc_92_
		loc_92_ = loc_91_;
		return 1228, loc_92_
	end)(), loc_125_, 0, 12)
	loc_122_[1] = (function(loc_93_)
		local loc_94_
		loc_94_ = loc_93_;
		return 77808, loc_94_
	end)();
	loc_123_[1] = (function(loc_95_)
		local loc_96_
		loc_96_ = loc_95_;
		return 0, loc_96_
	end)();
	rt_memory_drop(loc_124_)
	rt_memory_drop(loc_125_)
	loc_99_ = loc_98_;
	loc_114_ = loc_104_;
	loc_115_ = loc_103_;
	loc_116_ = loc_102_;
	loc_118_ = loc_101_;
	loc_121_ = loc_100_;
	local export = {
		["memory"] = loc_100_,
		["_initialize"] = loc_104_[1],
		["vc_init"] = loc_103_[1],
		["vc_frame"] = loc_102_[1],
		["pong_score"] = loc_101_[1],
		["__host"] = runtime.host_api,
	}
	return export
end
return module
