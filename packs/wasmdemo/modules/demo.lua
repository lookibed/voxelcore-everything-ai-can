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

do -- SECTION not_equal_i32
	local force_i32 = runtime.force_i32
local function rt_not_equal_i32(lhs, rhs)
	return force_i32(lhs) ~= force_i32(rhs)
end
	runtime.rt_not_equal_i32 = rt_not_equal_i32
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

do -- SECTION into_bits_i64
local function into_bits_i64(lo, hi)
	return { lo % 4294967296, hi % 4294967296 }
end
	runtime.into_bits_i64 = into_bits_i64
end

do -- SECTION load_i64
	local buffer_check, buffer_read_i32, into_bits_i64 = runtime.buffer_check, runtime.buffer_read_i32, runtime.into_bits_i64
local function rt_load_i64(source, base, offset)
	local memory = source[1]

	buffer_check(memory, base, offset, 8)

	local lo = buffer_read_i32(memory, base, offset)
	local hi = buffer_read_i32(memory, base, offset + 4)

	return into_bits_i64(lo, hi)
end
	runtime.rt_load_i64 = rt_load_i64
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

do -- SECTION equal_i32
	local force_i32 = runtime.force_i32
local function rt_equal_i32(lhs, rhs)
	return force_i32(lhs) == force_i32(rhs)
end
	runtime.rt_equal_i32 = rt_equal_i32
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

do -- SECTION add_f64
local function rt_add_f64(lhs, rhs)
	return lhs + rhs
end
	runtime.rt_add_f64 = rt_add_f64
end

do -- SECTION divide_f64
local function rt_divide_f64(lhs, rhs)
	return lhs / rhs
end
	runtime.rt_divide_f64 = rt_divide_f64
end

do -- SECTION multiply_f64
local function rt_multiply_f64(lhs, rhs)
	return lhs * rhs
end
	runtime.rt_multiply_f64 = rt_multiply_f64
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

do -- SECTION convert_u32_to_f64
	local force_u32 = runtime.force_u32
local function rt_convert_u32_to_f64(source)
	return force_u32(source) + 0.0
end
	runtime.rt_convert_u32_to_f64 = rt_convert_u32_to_f64
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

do -- SECTION store_f64
	local buffer_write_f64 = runtime.buffer_write_f64
local function rt_store_f64(destination, base, offset, source)
	buffer_write_f64(destination[1], base, offset, source)
end
	runtime.rt_store_f64 = rt_store_f64
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

do -- SECTION divide_f32
	local from_bits_f32, into_bits_f32 = runtime.from_bits_f32, runtime.into_bits_f32
local function rt_divide_f32(lhs, rhs)
	return into_bits_f32(from_bits_f32(lhs) / from_bits_f32(rhs))
end
	runtime.rt_divide_f32 = rt_divide_f32
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

do -- SECTION convert_s32_to_f32
	local force_s32, into_bits_f32 = runtime.force_s32, runtime.into_bits_f32
local function rt_convert_s32_to_f32(source)
	return into_bits_f32(force_s32(source) + 0.0)
end
	runtime.rt_convert_s32_to_f32 = rt_convert_s32_to_f32
end

do -- SECTION multiply_f32
	local from_bits_f32, into_bits_f32 = runtime.from_bits_f32, runtime.into_bits_f32
local function rt_multiply_f32(lhs, rhs)
	return into_bits_f32(from_bits_f32(lhs) * from_bits_f32(rhs))
end
	runtime.rt_multiply_f32 = rt_multiply_f32
end

do -- SECTION add_f32
	local from_bits_f32, into_bits_f32 = runtime.from_bits_f32, runtime.into_bits_f32
local function rt_add_f32(lhs, rhs)
	return into_bits_f32(from_bits_f32(lhs) + from_bits_f32(rhs))
end
	runtime.rt_add_f32 = rt_add_f32
end

do -- SECTION convert_u32_to_f32
	local force_u32, into_bits_f32 = runtime.force_u32, runtime.into_bits_f32
local function rt_convert_u32_to_f32(source)
	return into_bits_f32(force_u32(source) + 0.0)
end
	runtime.rt_convert_u32_to_f32 = rt_convert_u32_to_f32
end

do -- SECTION math_modf
local math_modf = math.modf
	runtime.math_modf = math_modf
end

do -- SECTION saturate_f64_to_u32
	local force_i32, math_modf = runtime.force_i32, runtime.math_modf
local function rt_saturate_f64_to_u32(source)
	if source ~= source then
		return 0
	end

	if source >= 4294967296.0 then
		return force_i32(0xFFFFFFFF)
	end

	if source <= 0 then
		return 0
	end

	source = math_modf(source)

	return force_i32(source)
end
	runtime.rt_saturate_f64_to_u32 = rt_saturate_f64_to_u32
end

do -- SECTION saturate_f32_to_u32
	local from_bits_f32, rt_saturate_f64_to_u32 = runtime.from_bits_f32, runtime.rt_saturate_f64_to_u32
local function rt_saturate_f32_to_u32(source)
	return rt_saturate_f64_to_u32(from_bits_f32(source))
end
	runtime.rt_saturate_f32_to_u32 = rt_saturate_f32_to_u32
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

do -- SECTION widen_f32
	local from_bits_f32 = runtime.from_bits_f32
local function rt_widen_f32(source)
	return from_bits_f32(source)
end
	runtime.rt_widen_f32 = rt_widen_f32
end

do -- SECTION bit32_and
	local bit = runtime.bit
local bit32_and = bit.band
	runtime.bit32_and = bit32_and
end

do -- SECTION and_i32
	local bit32_and = runtime.bit32_and
local rt_and_i32 = bit32_and
	runtime.rt_and_i32 = rt_and_i32
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

do -- SECTION less_than_u32
	local force_u32 = runtime.force_u32
local function rt_less_than_u32(lhs, rhs)
	lhs = force_u32(lhs)
	rhs = force_u32(rhs)

	return lhs < rhs
end
	runtime.rt_less_than_u32 = rt_less_than_u32
end

do -- SECTION narrow_f64
	local into_bits_f32 = runtime.into_bits_f32
local function rt_narrow_f64(source)
	return into_bits_f32(source)
end
	runtime.rt_narrow_f64 = rt_narrow_f64
end

do -- SECTION greater_than_equal_u32
	local force_u32 = runtime.force_u32
local function rt_greater_than_equal_u32(lhs, rhs)
	lhs = force_u32(lhs)
	rhs = force_u32(rhs)

	return lhs >= rhs
end
	runtime.rt_greater_than_equal_u32 = rt_greater_than_equal_u32
end

do -- SECTION less_than_equal_u32
	local force_u32 = runtime.force_u32
local function rt_less_than_equal_u32(lhs, rhs)
	lhs = force_u32(lhs)
	rhs = force_u32(rhs)

	return lhs <= rhs
end
	runtime.rt_less_than_equal_u32 = rt_less_than_equal_u32
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

do -- SECTION transmute_i64_to_f64
	local from_bits_f64, from_bits_i64 = runtime.from_bits_f64, runtime.from_bits_i64
local function rt_transmute_i64_to_f64(source)
	local lo, hi = from_bits_i64(source)

	return from_bits_f64(lo, hi)
end
	runtime.rt_transmute_i64_to_f64 = rt_transmute_i64_to_f64
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

do -- SECTION shift_left_i64
	local bit32_and, bit32_lshift, bit32_or, bit32_rshift, from_bits_i64, into_bits_i64 = runtime.bit32_and, runtime.bit32_lshift, runtime.bit32_or, runtime.bit32_rshift, runtime.from_bits_i64, runtime.into_bits_i64
local function rt_shift_left_i64(lhs, rhs)
	if type(rhs) == "table" then
		rhs, _ = from_bits_i64(rhs)
	end

	rhs = bit32_and(rhs, 0x3F)

	local lo, hi = from_bits_i64(lhs)

	if rhs == 0 then
		return into_bits_i64(lo, hi)
	end

	if rhs < 32 then
		local carry = bit32_rshift(lo, 32 - rhs)

		return into_bits_i64(bit32_lshift(lo, rhs), bit32_or(bit32_lshift(hi, rhs), carry))
	end

	if rhs == 32 then
		return into_bits_i64(0, lo)
	end

	return into_bits_i64(0, bit32_lshift(lo, rhs - 32))
end
	runtime.rt_shift_left_i64 = rt_shift_left_i64
end

do -- SECTION widen_i32
	local into_bits_i64 = runtime.into_bits_i64
local function rt_widen_i32(source)
	source = into_bits_i64(source, 0)

	return source
end
	runtime.rt_widen_i32 = rt_widen_i32
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

do -- SECTION shift_left_i32
	local bit32_and, bit32_lshift = runtime.bit32_and, runtime.bit32_lshift
local function rt_shift_left_i32(lhs, rhs)
	rhs = bit32_and(rhs, 0x1F)

	local result = bit32_lshift(lhs, rhs)

	return result
end
	runtime.rt_shift_left_i32 = rt_shift_left_i32
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

do -- SECTION convert_s32_to_f64
	local force_s32 = runtime.force_s32
local function rt_convert_s32_to_f64(source)
	return force_s32(source) + 0.0
end
	runtime.rt_convert_s32_to_f64 = rt_convert_s32_to_f64
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

do -- SECTION load_f64
	local buffer_read_f64 = runtime.buffer_read_f64
local function rt_load_f64(source, base, offset)
	return buffer_read_f64(source[1], base, offset)
end
	runtime.rt_load_f64 = rt_load_f64
end

do -- SECTION saturate_f64_to_s32
	local force_i32, math_modf = runtime.force_i32, runtime.math_modf
local function rt_saturate_f64_to_s32(source)
	if source ~= source then
		return 0
	end

	if source >= 2147483648.0 then
		return force_i32(0x7FFFFFFF)
	end

	if source <= -2147483648.0 then
		return force_i32(-2147483648)
	end

	source = math_modf(source)

	return force_i32(source)
end
	runtime.rt_saturate_f64_to_s32 = rt_saturate_f64_to_s32
end

do -- SECTION round_down_f64
	local math_floor = runtime.math_floor
local function rt_round_down_f64(source)
	local result = math_floor(source)

	return result
end
	runtime.rt_round_down_f64 = rt_round_down_f64
end

do -- SECTION subtract_f64
local function rt_subtract_f64(lhs, rhs)
	return lhs - rhs
end
	runtime.rt_subtract_f64 = rt_subtract_f64
end

do -- SECTION bit32_arshift
	local bit = runtime.bit
local bit32_arshift = bit.arshift
	runtime.bit32_arshift = bit32_arshift
end

do -- SECTION shift_right_s32
	local bit32_and, bit32_arshift = runtime.bit32_and, runtime.bit32_arshift
local function rt_shift_right_s32(lhs, rhs)
	rhs = bit32_and(rhs, 0x1F)

	local result = bit32_arshift(lhs, rhs)

	return result
end
	runtime.rt_shift_right_s32 = rt_shift_right_s32
end

do -- SECTION greater_than_equal_f64
local function rt_greater_than_equal_f64(lhs, rhs)
	return lhs >= rhs
end
	runtime.rt_greater_than_equal_f64 = rt_greater_than_equal_f64
end

do -- SECTION or_i32
	local bit32_or = runtime.bit32_or
local rt_or_i32 = bit32_or
	runtime.rt_or_i32 = rt_or_i32
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

do -- SECTION not_equal_f64
local function rt_not_equal_f64(lhs, rhs)
	return lhs ~= rhs
end
	runtime.rt_not_equal_f64 = rt_not_equal_f64
end

do -- SECTION negate_f64
local function rt_negate_f64(source)
	return -source
end
	runtime.rt_negate_f64 = rt_negate_f64
end

do -- SECTION transmute_f32_to_i32
local function rt_transmute_f32_to_i32(source)
	return source
end
	runtime.rt_transmute_f32_to_i32 = rt_transmute_f32_to_i32
end

do -- SECTION subtract_f32
	local from_bits_f32, into_bits_f32 = runtime.from_bits_f32, runtime.into_bits_f32
local function rt_subtract_f32(lhs, rhs)
	return into_bits_f32(from_bits_f32(lhs) - from_bits_f32(rhs))
end
	runtime.rt_subtract_f32 = rt_subtract_f32
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

do -- SECTION transmute_i32_to_f32
local function rt_transmute_i32_to_f32(source)
	return source
end
	runtime.rt_transmute_i32_to_f32 = rt_transmute_i32_to_f32
end

do -- SECTION bit32_xor
	local bit = runtime.bit
local bit32_xor = bit.bxor
	runtime.bit32_xor = bit32_xor
end

do -- SECTION negate_f32
	local bit32_xor = runtime.bit32_xor
local function rt_negate_f32(source)
	source = bit32_xor(source, 0x80000000)

	return source
end
	runtime.rt_negate_f32 = rt_negate_f32
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

do -- SECTION table_get_function
	local force_u32, rt_function_types = runtime.force_u32, runtime.rt_function_types
local function rt_table_get_function(source, offset, expected)
	offset = force_u32(offset)

	if offset >= source.minimum then
		error("undefined element", 0)
	end

	local result = source[offset]

	if result == nil then
		error("uninitialized element", 0)
	end

	local actual = rt_function_types[result]

	if actual ~= nil and actual ~= expected then
		error("indirect call type mismatch", 0)
	end

	return result
end
	runtime.rt_table_get_function = rt_table_get_function
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

do -- SECTION extend_s32_to_i64
	local into_bits_i64 = runtime.into_bits_i64
local function rt_extend_s32_to_i64(source)
	if type(source) == "table" then
		source = source[1]
	end

	source = source % 0x100000000

	if source >= 0x80000000 then
		return into_bits_i64(source - 0x100000000, 0xFFFFFFFF)
	end

	return into_bits_i64(source, 0)
end
	runtime.rt_extend_s32_to_i64 = rt_extend_s32_to_i64
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

do -- SECTION or_i64
	local bit32_or, from_bits_i64, into_bits_i64 = runtime.bit32_or, runtime.from_bits_i64, runtime.into_bits_i64
local function rt_or_i64(lhs, rhs)
	local lhs_lo, lhs_hi = from_bits_i64(lhs)
	local rhs_lo, rhs_hi = from_bits_i64(rhs)

	return into_bits_i64(bit32_or(lhs_lo, rhs_lo), bit32_or(lhs_hi, rhs_hi))
end
	runtime.rt_or_i64 = rt_or_i64
end

do -- SECTION exclusive_or_i32
	local bit32_xor = runtime.bit32_xor
local rt_exclusive_or_i32 = bit32_xor
	runtime.rt_exclusive_or_i32 = rt_exclusive_or_i32
end

do -- SECTION and_i64
	local bit32_and, from_bits_i64, into_bits_i64 = runtime.bit32_and, runtime.from_bits_i64, runtime.into_bits_i64
local function rt_and_i64(lhs, rhs)
	local lhs_lo, lhs_hi = from_bits_i64(lhs)
	local rhs_lo, rhs_hi = from_bits_i64(rhs)

	return into_bits_i64(bit32_and(lhs_lo, rhs_lo), bit32_and(lhs_hi, rhs_hi))
end
	runtime.rt_and_i64 = rt_and_i64
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

do -- SECTION load_i32_from_u16
	local buffer_read_u16 = runtime.buffer_read_u16
local function rt_load_i32_from_u16(source, base, offset)
	local result = buffer_read_u16(source[1], base, offset)

	return result
end
	runtime.rt_load_i32_from_u16 = rt_load_i32_from_u16
end

do -- SECTION equal_i64
	local from_bits_i64 = runtime.from_bits_i64
local function rt_equal_i64(lhs, rhs)
	local lhs_lo, lhs_hi = from_bits_i64(lhs)
	local rhs_lo, rhs_hi = from_bits_i64(rhs)

	return lhs_lo == rhs_lo and lhs_hi == rhs_hi
end
	runtime.rt_equal_i64 = rt_equal_i64
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

do -- SECTION load_i32_from_s8
	local buffer_read_i8 = runtime.buffer_read_i8
local function rt_load_i32_from_s8(source, base, offset)
	local result = buffer_read_i8(source[1], base, offset)

	return result
end
	runtime.rt_load_i32_from_s8 = rt_load_i32_from_s8
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

do -- SECTION memory_fill
	local buffer_fill = runtime.buffer_fill
local function rt_memory_fill(destination, offset, value, size)
	buffer_fill(destination[1], offset, value, size)
end
	runtime.rt_memory_fill = rt_memory_fill
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

do -- SECTION extend_s8_to_i32
	local bit32_and, bit32_or = runtime.bit32_and, runtime.bit32_or
local function rt_extend_s8_to_i32(source)
	source = bit32_and(source, 0xFF)

	if source >= 0x80 then
		source = bit32_or(source - 0x100, 0)
	end

	return source
end
	runtime.rt_extend_s8_to_i32 = rt_extend_s8_to_i32
end

do -- SECTION transmute_f64_to_i64
	local into_bits_f64, into_bits_i64 = runtime.into_bits_f64, runtime.into_bits_i64
local function rt_transmute_f64_to_i64(source)
	local lo, hi = into_bits_f64(source)

	return into_bits_i64(lo, hi)
end
	runtime.rt_transmute_f64_to_i64 = rt_transmute_f64_to_i64
end

do -- SECTION narrow_i64
	local from_bits_i64 = runtime.from_bits_i64
local function rt_narrow_i64(source)
	local lo, _ = from_bits_i64(source)

	return lo
end
	runtime.rt_narrow_i64 = rt_narrow_i64
end

do -- SECTION shift_right_u64
	local bit32_and, bit32_lshift, bit32_or, bit32_rshift, from_bits_i64, into_bits_i64 = runtime.bit32_and, runtime.bit32_lshift, runtime.bit32_or, runtime.bit32_rshift, runtime.from_bits_i64, runtime.into_bits_i64
local function rt_shift_right_u64(lhs, rhs)
	if type(rhs) == "table" then
		rhs, _ = from_bits_i64(rhs)
	end

	rhs = bit32_and(rhs, 0x3F)

	local lo, hi = from_bits_i64(lhs)

	if rhs == 0 then
		return into_bits_i64(lo, hi)
	end

	if rhs < 32 then
		local carry = bit32_lshift(hi, 32 - rhs)

		return into_bits_i64(bit32_or(bit32_rshift(lo, rhs), carry), bit32_rshift(hi, rhs))
	end

	if rhs == 32 then
		return into_bits_i64(hi, 0)
	end

	return into_bits_i64(bit32_rshift(hi, rhs - 32), 0)
end
	runtime.rt_shift_right_u64 = rt_shift_right_u64
end

do -- SECTION store_i64_into_i32
	local buffer_write_i32, from_bits_i64 = runtime.buffer_write_i32, runtime.from_bits_i64
local function rt_store_i64_into_i32(destination, base, offset, source)
	local lo = from_bits_i64(source)

	buffer_write_i32(destination[1], base, offset, lo)
end
	runtime.rt_store_i64_into_i32 = rt_store_i64_into_i32
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

do -- SECTION less_than_u64
	local from_bits_i64 = runtime.from_bits_i64
local function rt_less_than_u64(lhs, rhs)
	local lhs_lo, lhs_hi = from_bits_i64(lhs)
	local rhs_lo, rhs_hi = from_bits_i64(rhs)

	if lhs_hi ~= rhs_hi then
		return lhs_hi < rhs_hi
	end

	return lhs_lo < rhs_lo
end
	runtime.rt_less_than_u64 = rt_less_than_u64
end

do -- SECTION greater_than_u64
	local rt_less_than_u64 = runtime.rt_less_than_u64
local function rt_greater_than_u64(lhs, rhs)
	return rt_less_than_u64(rhs, lhs)
end
	runtime.rt_greater_than_u64 = rt_greater_than_u64
end

do -- SECTION less_than_s64
	local from_bits_i64 = runtime.from_bits_i64
local function rt_less_than_s64(lhs, rhs)
	local lhs_lo, lhs_hi = from_bits_i64(lhs)
	local rhs_lo, rhs_hi = from_bits_i64(rhs)
	local lhs_negative = lhs_hi >= 0x80000000
	local rhs_negative = rhs_hi >= 0x80000000

	if lhs_negative ~= rhs_negative then
		return lhs_negative
	end

	if lhs_hi ~= rhs_hi then
		return lhs_hi < rhs_hi
	end

	return lhs_lo < rhs_lo
end
	runtime.rt_less_than_s64 = rt_less_than_s64
end

do -- SECTION greater_than_s64
	local rt_less_than_s64 = runtime.rt_less_than_s64
local function rt_greater_than_s64(lhs, rhs)
	return rt_less_than_s64(rhs, lhs)
end
	runtime.rt_greater_than_s64 = rt_greater_than_s64
end

do -- SECTION equal_f64
local function rt_equal_f64(lhs, rhs)
	return lhs == rhs
end
	runtime.rt_equal_f64 = rt_equal_f64
end

do -- SECTION load_i64_from_u32
	local buffer_read_i32, into_bits_i64 = runtime.buffer_read_i32, runtime.into_bits_i64
local function rt_load_i64_from_u32(source, base, offset)
	local val = buffer_read_i32(source[1], base, offset)

	return into_bits_i64(val, 0)
end
	runtime.rt_load_i64_from_u32 = rt_load_i64_from_u32
end

do -- SECTION add_i64
	local from_bits_i64, into_bits_i64 = runtime.from_bits_i64, runtime.into_bits_i64
local function rt_add_i64(lhs, rhs)
	local lhs_lo, lhs_hi = from_bits_i64(lhs)
	local rhs_lo, rhs_hi = from_bits_i64(rhs)

	local lo = lhs_lo + rhs_lo
	local hi = lhs_hi + rhs_hi

	if lo >= 0x100000000 then
		lo = lo - 0x100000000
		hi = hi + 1
	end

	return into_bits_i64(lo, hi)
end
	runtime.rt_add_i64 = rt_add_i64
end

do -- SECTION raw_compare_u64
local function raw_compare_u64(lhs_lo, lhs_hi, rhs_lo, rhs_hi)
	if lhs_hi ~= rhs_hi then
		if lhs_hi < rhs_hi then
			return -1
		end

		return 1
	end

	if lhs_lo ~= rhs_lo then
		if lhs_lo < rhs_lo then
			return -1
		end

		return 1
	end

	return 0
end
	runtime.raw_compare_u64 = raw_compare_u64
end

do -- SECTION raw_shift_left_one_u64
	local bit32_lshift, bit32_or, bit32_rshift, force_u32 = runtime.bit32_lshift, runtime.bit32_or, runtime.bit32_rshift, runtime.force_u32
local function raw_shift_left_one_u64(lo, hi)
	local new_lo = force_u32(bit32_lshift(lo, 1))
	local new_hi = force_u32(bit32_or(bit32_lshift(hi, 1), bit32_rshift(lo, 31)))

	return new_lo, new_hi
end
	runtime.raw_shift_left_one_u64 = raw_shift_left_one_u64
end

do -- SECTION raw_subtract_u64
local function raw_subtract_u64(lhs_lo, lhs_hi, rhs_lo, rhs_hi)
	local lo = lhs_lo - rhs_lo
	local hi = lhs_hi - rhs_hi

	if lo < 0 then
		lo = lo + 0x100000000
		hi = hi - 1
	end

	return lo, hi
end
	runtime.raw_subtract_u64 = raw_subtract_u64
end

do -- SECTION raw_unsigned_divide_u64
	local bit, bit32_and, bit32_rshift, from_bits_i64, into_bits_i64, raw_compare_u64, raw_shift_left_one_u64, raw_subtract_u64 = runtime.bit, runtime.bit32_and, runtime.bit32_rshift, runtime.from_bits_i64, runtime.into_bits_i64, runtime.raw_compare_u64, runtime.raw_shift_left_one_u64, runtime.raw_subtract_u64
local function raw_unsigned_divide_u64(lhs, rhs)
	local lhs_lo, lhs_hi = from_bits_i64(lhs)
	local rhs_lo, rhs_hi = from_bits_i64(rhs)
	local quotient_lo = 0
	local quotient_hi = 0
	local remainder_lo = 0
	local remainder_hi = 0

	for bit = 63, 0, -1 do
		remainder_lo, remainder_hi = raw_shift_left_one_u64(remainder_lo, remainder_hi)

		local incoming

		if bit >= 32 then
			incoming = bit32_and(bit32_rshift(lhs_hi, bit - 32), 1)
		else
			incoming = bit32_and(bit32_rshift(lhs_lo, bit), 1)
		end

		remainder_lo = remainder_lo + incoming

		if raw_compare_u64(remainder_lo, remainder_hi, rhs_lo, rhs_hi) >= 0 then
			remainder_lo, remainder_hi = raw_subtract_u64(remainder_lo, remainder_hi, rhs_lo, rhs_hi)

			if bit >= 32 then
				quotient_hi = quotient_hi + 2 ^ (bit - 32)
			else
				quotient_lo = quotient_lo + 2 ^ bit
			end
		end
	end

	return into_bits_i64(quotient_lo, quotient_hi), into_bits_i64(remainder_lo, remainder_hi)
end
	runtime.raw_unsigned_divide_u64 = raw_unsigned_divide_u64
end

do -- SECTION divide_u64
	local from_bits_i64, raw_unsigned_divide_u64 = runtime.from_bits_i64, runtime.raw_unsigned_divide_u64
local function rt_divide_u64(lhs, rhs)
	local rhs_lo, rhs_hi = from_bits_i64(rhs)

	if rhs_lo == 0 and rhs_hi == 0 then
		error("integer divide by zero")
	end

	local quotient = raw_unsigned_divide_u64(lhs, rhs)

	return quotient
end
	runtime.rt_divide_u64 = rt_divide_u64
end

do -- SECTION subtract_i64
	local from_bits_i64, into_bits_i64 = runtime.from_bits_i64, runtime.into_bits_i64
local function rt_subtract_i64(lhs, rhs)
	local lhs_lo, lhs_hi = from_bits_i64(lhs)
	local rhs_lo, rhs_hi = from_bits_i64(rhs)

	local lo = lhs_lo - rhs_lo
	local hi = lhs_hi - rhs_hi

	if lo < 0 then
		lo = lo + 0x100000000
		hi = hi - 1
	end

	return into_bits_i64(lo, hi)
end
	runtime.rt_subtract_i64 = rt_subtract_i64
end

do -- SECTION multiply_i64
	local from_bits_i64, into_bits_i64 = runtime.from_bits_i64, runtime.into_bits_i64
local function rt_multiply_i64(lhs, rhs)
	local lhs_lo, lhs_hi = from_bits_i64(lhs)
	local rhs_lo, rhs_hi = from_bits_i64(rhs)

	local a0 = lhs_lo % 0x10000
	local a1 = math.floor(lhs_lo / 0x10000)
	local a2 = lhs_hi % 0x10000
	local a3 = math.floor(lhs_hi / 0x10000)
	local b0 = rhs_lo % 0x10000
	local b1 = math.floor(rhs_lo / 0x10000)
	local b2 = rhs_hi % 0x10000
	local b3 = math.floor(rhs_hi / 0x10000)

	local carry = 0

	local digit0 = a0 * b0
	local c0 = digit0 % 0x10000
	carry = math.floor(digit0 / 0x10000)

	local digit1 = carry + a0 * b1 + a1 * b0
	local c1 = digit1 % 0x10000
	carry = math.floor(digit1 / 0x10000)

	local digit2 = carry + a0 * b2 + a1 * b1 + a2 * b0
	local c2 = digit2 % 0x10000
	carry = math.floor(digit2 / 0x10000)

	local digit3 = carry + a0 * b3 + a1 * b2 + a2 * b1 + a3 * b0
	local c3 = digit3 % 0x10000

	local lo = c0 + c1 * 0x10000
	local hi = c2 + c3 * 0x10000

	return into_bits_i64(lo, hi)
end
	runtime.rt_multiply_i64 = rt_multiply_i64
end

do -- SECTION less_than_f64
local function rt_less_than_f64(lhs, rhs)
	return lhs < rhs
end
	runtime.rt_less_than_f64 = rt_less_than_f64
end

do -- SECTION greater_than_equal_u64
	local rt_less_than_u64 = runtime.rt_less_than_u64
local function rt_greater_than_equal_u64(lhs, rhs)
	return not rt_less_than_u64(lhs, rhs)
end
	runtime.rt_greater_than_equal_u64 = rt_greater_than_equal_u64
end

do -- SECTION not_equal_i64
	local rt_equal_i64 = runtime.rt_equal_i64
local function rt_not_equal_i64(lhs, rhs)
	return not rt_equal_i64(lhs, rhs)
end
	runtime.rt_not_equal_i64 = rt_not_equal_i64
end

do -- SECTION load_i64_from_s32
	local buffer_read_i32, into_bits_i64 = runtime.buffer_read_i32, runtime.into_bits_i64
local function rt_load_i64_from_s32(source, base, offset)
	local val = buffer_read_i32(source[1], base, offset)

	if val >= 0 then
		return into_bits_i64(val, 0)
	else
		return into_bits_i64(val + 0x100000000, 0xFFFFFFFF)
	end
end
	runtime.rt_load_i64_from_s32 = rt_load_i64_from_s32
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

do -- SECTION load_i64_from_s16
	local buffer_read_i16, into_bits_i64 = runtime.buffer_read_i16, runtime.into_bits_i64
local function rt_load_i64_from_s16(source, base, offset)
	local val = buffer_read_i16(source[1], base, offset)

	if val >= 0 then
		return into_bits_i64(val, 0)
	else
		return into_bits_i64(val + 0x100000000, 0xFFFFFFFF)
	end
end
	runtime.rt_load_i64_from_s16 = rt_load_i64_from_s16
end

do -- SECTION load_i64_from_u16
	local buffer_read_u16, into_bits_i64 = runtime.buffer_read_u16, runtime.into_bits_i64
local function rt_load_i64_from_u16(source, base, offset)
	local val = buffer_read_u16(source[1], base, offset)

	return into_bits_i64(val, 0)
end
	runtime.rt_load_i64_from_u16 = rt_load_i64_from_u16
end

do -- SECTION load_i64_from_s8
	local buffer_read_i8, into_bits_i64 = runtime.buffer_read_i8, runtime.into_bits_i64
local function rt_load_i64_from_s8(source, base, offset)
	local val = buffer_read_i8(source[1], base, offset)

	if val >= 0 then
		return into_bits_i64(val, 0)
	else
		return into_bits_i64(val + 0x100000000, 0xFFFFFFFF)
	end
end
	runtime.rt_load_i64_from_s8 = rt_load_i64_from_s8
end

do -- SECTION load_i64_from_u8
	local buffer_read_u8, into_bits_i64 = runtime.buffer_read_u8, runtime.into_bits_i64
local function rt_load_i64_from_u8(source, base, offset)
	local val = buffer_read_u8(source[1], base, offset)

	return into_bits_i64(val, 0)
end
	runtime.rt_load_i64_from_u8 = rt_load_i64_from_u8
end

do -- SECTION memory_size
	local buffer_len = runtime.buffer_len
local function rt_memory_size(source)
	return buffer_len(source[1])
end
	runtime.rt_memory_size = rt_memory_size
end

do -- SECTION buffer_resize
	local math_floor = runtime.math_floor
-- Grows the word array to cover `size` bytes and only then publishes the new
-- length, so a failed allocation leaves the memory exactly as it was.
local function buffer_resize(buf, size)
	local words = buf.__w
	local old = math_floor(buf.__n / 4) + 2
	local new = math_floor(size / 4) + 2

	for index = old + 1, new do
		words[index] = 0
	end

	rawset(buf, "__n", size)
end
	runtime.buffer_resize = buffer_resize
end

do -- SECTION memory_grow
	local buffer_len, buffer_resize = runtime.buffer_len, runtime.buffer_resize
local function rt_memory_grow(destination, size)
	-- `size` is a byte count produced by an `i32` multiply, so it may have
	-- wrapped negative; the frontend guarantees it fits in 32 unsigned bits.
	if size < 0 then
		size = size + 0x100000000
	end

	local old = buffer_len(destination[1])
	local new = old + size

	-- Lua numbers address the word array exactly up to 2^53, but keep memories
	-- below 2 GiB so byte offsets stay valid `i32` values on every path.
	if new > destination.maximum or new >= 0x80000000 then
		return -1
	end

	buffer_resize(destination[1], new)

	return old
end
	runtime.rt_memory_grow = rt_memory_grow
end

do -- SECTION bit32_lrotate
	local bit = runtime.bit
local bit32_lrotate = bit.rol
	runtime.bit32_lrotate = bit32_lrotate
end

do -- SECTION rotate_left_i32
	local bit32_and, bit32_lrotate = runtime.bit32_and, runtime.bit32_lrotate
local function rt_rotate_left_i32(lhs, rhs)
	rhs = bit32_and(rhs, 0x1F)

	local result = bit32_lrotate(lhs, rhs)

	return result
end
	runtime.rt_rotate_left_i32 = rt_rotate_left_i32
end

do -- SECTION bit32
	local bit = runtime.bit
local bit32 = {}

local function bit32_countlz_impl(x)
	x = bit.band(x, 0xFFFFFFFF)

	if x == 0 then
		return 32
	end

	local count = 0

	while bit.band(x, 0x80000000) == 0 do
		x = bit.lshift(x, 1)
		count = count + 1
	end

	return count
end

local function bit32_countrz_impl(x)
	x = bit.band(x, 0xFFFFFFFF)

	if x == 0 then
		return 32
	end

	local count = 0

	while bit.band(x, 1) == 0 do
		x = bit.rshift(x, 1)
		count = count + 1
	end

	return count
end

bit32.countlz = bit32_countlz_impl
bit32.countrz = bit32_countrz_impl
	runtime.bit32 = bit32
	runtime.bit32_countlz_impl = bit32_countlz_impl
	runtime.bit32_countrz_impl = bit32_countrz_impl
end

do -- SECTION bit32_countrz
	local bit32_countrz_impl = runtime.bit32_countrz_impl
local bit32_countrz = bit32_countrz_impl
	runtime.bit32_countrz = bit32_countrz
end

do -- SECTION trailing_zeroes_i32
	local bit32_countrz = runtime.bit32_countrz
local rt_trailing_zeroes_i32 = bit32_countrz
	runtime.rt_trailing_zeroes_i32 = rt_trailing_zeroes_i32
end

do -- SECTION bit32_countlz
	local bit32_countlz_impl = runtime.bit32_countlz_impl
local bit32_countlz = bit32_countlz_impl
	runtime.bit32_countlz = bit32_countlz
end

do -- SECTION leading_zeroes_i32
	local bit32_countlz = runtime.bit32_countlz
local rt_leading_zeroes_i32 = bit32_countlz
	runtime.rt_leading_zeroes_i32 = rt_leading_zeroes_i32
end

do -- SECTION table_set
	local force_u32 = runtime.force_u32
local function rt_table_set(destination, offset, source)
	offset = force_u32(offset)

	if offset >= destination.minimum then
		error("out of bounds table access", 0)
	end

	destination[offset] = source
end
	runtime.rt_table_set = rt_table_set
end

do -- SECTION table_copy
	local force_u32 = runtime.force_u32
local function rt_table_copy(destination, offset_1, source, offset_2, size)
	offset_1 = force_u32(offset_1)
	offset_2 = force_u32(offset_2)
	size = force_u32(size)

	if offset_1 + size > destination.minimum or offset_2 + size > source.minimum then
		error("out of bounds table access", 0)
	end

	if offset_1 <= offset_2 then
		for i = 0, size - 1 do
			destination[offset_1 + i] = source[offset_2 + i]
		end
	else
		for i = size - 1, 0, -1 do
			destination[offset_1 + i] = source[offset_2 + i]
		end
	end
end
	runtime.rt_table_copy = rt_table_copy
end

do -- SECTION table_drop
local function rt_table_drop(destination)
	for offset = 0, destination.minimum - 1 do
		destination[offset] = nil
	end

	destination.minimum = 0
	destination.maximum = 0
end
	runtime.rt_table_drop = rt_table_drop
end

do -- SECTION memory_drop
	local buffer_create = runtime.buffer_create
local function rt_memory_drop(destination)
	destination[1] = buffer_create(0)
	destination.maximum = 0
end
	runtime.rt_memory_drop = rt_memory_drop
end

do -- SECTION buffer_read_f32
	local buffer_read_i32, from_bits_f32 = runtime.buffer_read_i32, runtime.from_bits_f32
local function buffer_read_f32(buf, base, offset)
	return from_bits_f32(buffer_read_i32(buf, base, offset))
end
	runtime.buffer_read_f32 = buffer_read_f32
end

do -- SECTION buffer_write_f32
	local buffer_write_i32, into_bits_f32 = runtime.buffer_write_i32, runtime.into_bits_f32
local function buffer_write_f32(buf, base, offset, value)
	buffer_write_i32(buf, base, offset, into_bits_f32(value))
end
	runtime.buffer_write_f32 = buffer_write_f32
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

local function module(loc_1271_)
	local excess_stack = { top = 0 }
	local rt_yield_budget = 20000
	runtime.host_api.has_yield_points = true
	local rt_add_f32 = runtime.rt_add_f32
	local rt_add_f64 = runtime.rt_add_f64
	local rt_add_i64 = runtime.rt_add_i64
	local rt_and_i32 = runtime.rt_and_i32
	local rt_and_i64 = runtime.rt_and_i64
	local bit32_or = runtime.bit32_or
	local buffer_read_i32 = runtime.buffer_read_i32
	local rt_convert_s32_to_f32 = runtime.rt_convert_s32_to_f32
	local rt_convert_s32_to_f64 = runtime.rt_convert_s32_to_f64
	local rt_convert_u32_to_f32 = runtime.rt_convert_u32_to_f32
	local rt_convert_u32_to_f64 = runtime.rt_convert_u32_to_f64
	local rt_divide_f32 = runtime.rt_divide_f32
	local rt_divide_f64 = runtime.rt_divide_f64
	local rt_divide_s32 = runtime.rt_divide_s32
	local rt_divide_u32 = runtime.rt_divide_u32
	local rt_divide_u64 = runtime.rt_divide_u64
	local rt_equal_f64 = runtime.rt_equal_f64
	local rt_equal_i32 = runtime.rt_equal_i32
	local rt_equal_i64 = runtime.rt_equal_i64
	local rt_exclusive_or_i32 = runtime.rt_exclusive_or_i32
	local rt_extend_s32_to_i64 = runtime.rt_extend_s32_to_i64
	local rt_extend_s8_to_i32 = runtime.rt_extend_s8_to_i32
	local from_bits_f64 = runtime.from_bits_f64
	local rt_function_type = runtime.rt_function_type
	local rt_greater_than_equal_f64 = runtime.rt_greater_than_equal_f64
	local rt_greater_than_equal_s32 = runtime.rt_greater_than_equal_s32
	local rt_greater_than_equal_u32 = runtime.rt_greater_than_equal_u32
	local rt_greater_than_equal_u64 = runtime.rt_greater_than_equal_u64
	local rt_greater_than_s32 = runtime.rt_greater_than_s32
	local rt_greater_than_s64 = runtime.rt_greater_than_s64
	local rt_greater_than_u32 = runtime.rt_greater_than_u32
	local rt_greater_than_u64 = runtime.rt_greater_than_u64
	local into_bits_i64 = runtime.into_bits_i64
	local rt_leading_zeroes_i32 = runtime.rt_leading_zeroes_i32
	local rt_less_than_equal_s32 = runtime.rt_less_than_equal_s32
	local rt_less_than_equal_u32 = runtime.rt_less_than_equal_u32
	local rt_less_than_f64 = runtime.rt_less_than_f64
	local rt_less_than_s32 = runtime.rt_less_than_s32
	local rt_less_than_u32 = runtime.rt_less_than_u32
	local rt_less_than_u64 = runtime.rt_less_than_u64
	local rt_load_f64 = runtime.rt_load_f64
	local rt_load_i32_from_s8 = runtime.rt_load_i32_from_s8
	local rt_load_i32_from_u16 = runtime.rt_load_i32_from_u16
	local rt_load_i32_from_u8 = runtime.rt_load_i32_from_u8
	local rt_load_i64 = runtime.rt_load_i64
	local rt_load_i64_from_s16 = runtime.rt_load_i64_from_s16
	local rt_load_i64_from_s32 = runtime.rt_load_i64_from_s32
	local rt_load_i64_from_s8 = runtime.rt_load_i64_from_s8
	local rt_load_i64_from_u16 = runtime.rt_load_i64_from_u16
	local rt_load_i64_from_u32 = runtime.rt_load_i64_from_u32
	local rt_load_i64_from_u8 = runtime.rt_load_i64_from_u8
	local rt_memory_copy = runtime.rt_memory_copy
	local rt_memory_drop = runtime.rt_memory_drop
	local rt_memory_fill = runtime.rt_memory_fill
	local rt_memory_grow = runtime.rt_memory_grow
	local rt_memory_new = runtime.rt_memory_new
	local rt_memory_size = runtime.rt_memory_size
	local rt_multiply_f32 = runtime.rt_multiply_f32
	local rt_multiply_f64 = runtime.rt_multiply_f64
	local rt_multiply_i32 = runtime.rt_multiply_i32
	local rt_multiply_i64 = runtime.rt_multiply_i64
	local rt_narrow_f64 = runtime.rt_narrow_f64
	local rt_narrow_i64 = runtime.rt_narrow_i64
	local rt_negate_f32 = runtime.rt_negate_f32
	local rt_negate_f64 = runtime.rt_negate_f64
	local rt_not_equal_f64 = runtime.rt_not_equal_f64
	local rt_not_equal_i32 = runtime.rt_not_equal_i32
	local rt_not_equal_i64 = runtime.rt_not_equal_i64
	local rt_or_i32 = runtime.rt_or_i32
	local rt_or_i64 = runtime.rt_or_i64
	local rt_remainder_u32 = runtime.rt_remainder_u32
	local rt_rotate_left_i32 = runtime.rt_rotate_left_i32
	local rt_round_down_f64 = runtime.rt_round_down_f64
	local rt_saturate_f32_to_u32 = runtime.rt_saturate_f32_to_u32
	local rt_saturate_f64_to_s32 = runtime.rt_saturate_f64_to_s32
	local rt_saturate_f64_to_u32 = runtime.rt_saturate_f64_to_u32
	local rt_shift_left_i32 = runtime.rt_shift_left_i32
	local rt_shift_left_i64 = runtime.rt_shift_left_i64
	local rt_shift_right_s32 = runtime.rt_shift_right_s32
	local rt_shift_right_u32 = runtime.rt_shift_right_u32
	local rt_shift_right_u64 = runtime.rt_shift_right_u64
	local rt_store_f64 = runtime.rt_store_f64
	local rt_store_i32 = runtime.rt_store_i32
	local rt_store_i32_into_i16 = runtime.rt_store_i32_into_i16
	local rt_store_i32_into_i8 = runtime.rt_store_i32_into_i8
	local rt_store_i64 = runtime.rt_store_i64
	local rt_store_i64_into_i32 = runtime.rt_store_i64_into_i32
	local rt_subtract_f32 = runtime.rt_subtract_f32
	local rt_subtract_f64 = runtime.rt_subtract_f64
	local rt_subtract_i64 = runtime.rt_subtract_i64
	local rt_table_copy = runtime.rt_table_copy
	local rt_table_drop = runtime.rt_table_drop
	local rt_table_get_function = runtime.rt_table_get_function
	local rt_table_new = runtime.rt_table_new
	local rt_table_set = runtime.rt_table_set
	local rt_trailing_zeroes_i32 = runtime.rt_trailing_zeroes_i32
	local rt_transmute_f32_to_i32 = runtime.rt_transmute_f32_to_i32
	local rt_transmute_f64_to_i64 = runtime.rt_transmute_f64_to_i64
	local rt_transmute_i32_to_f32 = runtime.rt_transmute_i32_to_f32
	local rt_transmute_i64_to_f64 = runtime.rt_transmute_i64_to_f64
	local rt_widen_f32 = runtime.rt_widen_f32
	local rt_widen_i32 = runtime.rt_widen_i32
	local rt_yield_point = runtime.rt_yield_point
	local module_locals = {}
	for i = 1, 118 do
		module_locals[i] = 0
	end
	module_locals[5] = { assert(loc_1271_["vc"]["time_ms"], '`vc.time_ms` should be present') };
	module_locals[6] = { assert(loc_1271_["vc"]["key_down"], '`vc.key_down` should be present') };
	module_locals[7] = { assert(loc_1271_["vc"]["gfx_present"], '`vc.gfx_present` should be present') };
	module_locals[8] = { assert(loc_1271_["wasi_snapshot_preview1"]["args_get"], '`wasi_snapshot_preview1.args_get` should be present') };
	module_locals[9] = { assert(loc_1271_["wasi_snapshot_preview1"]["args_sizes_get"], '`wasi_snapshot_preview1.args_sizes_get` should be present') };
	module_locals[10] = { assert(loc_1271_["wasi_snapshot_preview1"]["fd_close"], '`wasi_snapshot_preview1.fd_close` should be present') };
	module_locals[11] = { assert(loc_1271_["wasi_snapshot_preview1"]["fd_fdstat_get"], '`wasi_snapshot_preview1.fd_fdstat_get` should be present') };
	module_locals[12] = { assert(loc_1271_["wasi_snapshot_preview1"]["fd_fdstat_set_flags"], '`wasi_snapshot_preview1.fd_fdstat_set_flags` should be present') };
	module_locals[13] = { assert(loc_1271_["wasi_snapshot_preview1"]["fd_prestat_get"], '`wasi_snapshot_preview1.fd_prestat_get` should be present') };
	module_locals[14] = { assert(loc_1271_["wasi_snapshot_preview1"]["fd_prestat_dir_name"], '`wasi_snapshot_preview1.fd_prestat_dir_name` should be present') };
	module_locals[15] = { assert(loc_1271_["wasi_snapshot_preview1"]["fd_read"], '`wasi_snapshot_preview1.fd_read` should be present') };
	module_locals[16] = { assert(loc_1271_["wasi_snapshot_preview1"]["fd_seek"], '`wasi_snapshot_preview1.fd_seek` should be present') };
	module_locals[17] = { assert(loc_1271_["wasi_snapshot_preview1"]["fd_write"], '`wasi_snapshot_preview1.fd_write` should be present') };
	module_locals[18] = { assert(loc_1271_["wasi_snapshot_preview1"]["path_open"], '`wasi_snapshot_preview1.path_open` should be present') };
	module_locals[19] = { assert(loc_1271_["wasi_snapshot_preview1"]["proc_exit"], '`wasi_snapshot_preview1.proc_exit` should be present') };
	module_locals[20] = { nil };
	module_locals[20][1] = rt_function_type((function(loc_0_)
		local loc_1_
		loc_1_ = loc_0_;
		return loc_1_
	end), "->");
	module_locals[21] = { nil };
	module_locals[21][1] = rt_function_type((function(loc_2_, loc_3_, loc_4_, loc_5_, loc_6_, loc_7_)
		local loc_8_, loc_9_
		loc_8_ = loc_7_;
		loc_9_ = error('unreachable code');
		return loc_2_, loc_8_
	end), "i32,i32,i32,i32,i32->i32");
	module_locals[4] = { nil };
	module_locals[25] = { nil };
	module_locals[37] = { nil };
	module_locals[38] = { nil };
	module_locals[40] = { nil };
	module_locals[115] = { nil };
	module_locals[3] = rt_memory_new({ }, 196608, 4294967295);
	module_locals[4][1] = (function(loc_10_, loc_11_, loc_12_, loc_13_, loc_14_, loc_15_, loc_16_)
		return rt_function_type((function(loc_17_)
			local loc_18_, loc_19_, loc_20_, loc_21_, loc_22_, loc_23_, loc_24_, loc_25_, loc_26_, loc_27_
			loc_27_ = loc_15_[1];
			loc_19_ = loc_15_;
			loc_27_ = buffer_read_i32(loc_16_[1], bit32_or(loc_27_ + 6720, 0), 0);
			loc_20_ = loc_16_;
			if rt_not_equal_i32(loc_27_, 0) then
				loc_18_ = loc_17_;
				loc_21_ = loc_10_;
				loc_22_ = loc_11_;
				loc_23_ = loc_12_;
				loc_24_ = loc_13_;
				loc_25_ = loc_14_;
				loc_26_ = error('unreachable code');
			else
				loc_18_ = loc_17_;
				loc_21_ = loc_10_;
				loc_22_ = loc_11_;
				loc_23_ = loc_12_;
				loc_24_ = loc_13_;
				loc_25_ = loc_14_;
				loc_27_ = loc_19_[1];
				rt_store_i32(loc_20_, bit32_or(loc_27_ + 6720, 0), 0, 1)
				loc_27_ = loc_18_;
				loc_24_[1](loc_27_)
				loc_21_[1](loc_27_)
				loc_18_ = loc_22_[1](loc_27_)
				loc_25_[1](loc_27_)
				if rt_not_equal_i32(loc_18_, 0) then
					loc_27_ = loc_23_;
					loc_23_ = loc_27_;
					loc_27_[1](loc_18_, loc_26_)
					loc_26_ = error('unreachable code');
				else
					loc_27_ = loc_23_;
					loc_23_ = loc_18_;
					loc_23_ = loc_27_;
					loc_18_ = loc_26_;
				end
			end
			return loc_18_
		end), "->")
	end)(module_locals[20], module_locals[25], module_locals[37], module_locals[38], module_locals[40], module_locals[115], module_locals[3]);
	module_locals[23] = { nil };
	module_locals[46] = { nil };
	module_locals[48] = { nil };
	module_locals[53] = { nil };
	module_locals[73] = { nil };
	module_locals[77] = { nil };
	module_locals[83] = { nil };
	module_locals[89] = { nil };
	module_locals[114] = { nil };
	module_locals[23][1] = (function(loc_28_, loc_29_, loc_30_, loc_31_, loc_32_, loc_33_, loc_34_, loc_35_, loc_36_, loc_37_, loc_38_, loc_39_)
		return rt_function_type((function(loc_40_, loc_41_, loc_42_)
			local loc_43_, loc_44_, loc_45_, loc_46_, loc_47_, loc_48_, loc_49_, loc_50_, loc_51_, loc_52_, loc_53_, loc_54_, loc_55_, loc_56_, loc_57_, loc_58_, loc_59_, loc_60_, loc_61_, loc_62_, loc_63_, loc_64_, loc_65_, loc_66_, loc_67_, loc_68_, loc_69_, loc_70_
			loc_70_ = loc_38_[1];
			loc_44_ = loc_38_;
			loc_46_ = bit32_or(loc_70_ - 128, 0);
			loc_44_[1] = loc_46_;
			loc_70_ = buffer_read_i32(loc_39_[1], loc_41_, 0);
			loc_45_ = loc_39_;
			rt_store_i32(loc_45_, loc_46_, 52, loc_70_)
			rt_store_i32(loc_45_, loc_46_, 48, loc_40_)
			loc_70_ = loc_42_;
			loc_69_ = loc_35_[1](1115, bit32_or(loc_46_ + 48, 0), loc_70_)
			loc_68_ = loc_34_[1](1053, 1066, loc_70_)
			loc_69_ = rt_load_i64(loc_45_, 0, 1416);
			rt_store_i64(loc_45_, bit32_or(loc_46_ + 120, 0), 0, loc_69_)
			loc_69_ = rt_load_i64(loc_45_, 0, 1408);
			rt_store_i64(loc_45_, bit32_or(loc_46_ + 112, 0), 0, loc_69_)
			loc_69_ = rt_load_i64(loc_45_, 0, 1400);
			rt_store_i64(loc_45_, bit32_or(loc_46_ + 104, 0), 0, loc_69_)
			loc_69_ = rt_load_i64(loc_45_, 0, 1392);
			rt_store_i64(loc_45_, bit32_or(loc_46_ + 96, 0), 0, loc_69_)
			loc_69_ = rt_load_i64(loc_45_, 0, 1384);
			rt_store_i64(loc_45_, bit32_or(loc_46_ + 88, 0), 0, loc_69_)
			loc_69_ = rt_load_i64(loc_45_, 0, 1376);
			rt_store_i64(loc_45_, bit32_or(loc_46_ + 80, 0), 0, loc_69_)
			loc_69_ = rt_load_i64(loc_45_, 0, 1368);
			rt_store_i64(loc_45_, loc_46_, 72, loc_69_)
			loc_69_ = rt_load_i64(loc_45_, 0, 1360);
			rt_store_i64(loc_45_, loc_46_, 64, loc_69_)
			if rt_equal_i32(loc_68_, 0) then
				loc_43_ = loc_36_;
				loc_49_ = loc_29_;
				loc_50_ = loc_30_;
				loc_51_ = loc_31_;
				loc_52_ = loc_32_;
				loc_53_ = loc_33_;
				loc_54_ = loc_34_;
				loc_56_ = loc_37_;
				loc_67_ = loc_35_;
				loc_69_ = loc_28_;
			else
				loc_43_ = loc_36_;
				loc_49_ = loc_29_;
				loc_50_ = loc_30_;
				loc_51_ = loc_31_;
				loc_52_ = loc_32_;
				loc_53_ = loc_33_;
				loc_54_ = loc_34_;
				loc_56_ = loc_37_;
				loc_67_ = loc_35_;
				loc_69_ = loc_28_;
				loc_66_ = loc_53_[1](bit32_or(loc_46_ + 64, 0), 64, loc_68_, loc_70_)
				if rt_not_equal_i32(loc_66_, 0) then
					loc_65_ = loc_56_;
					loc_66_ = loc_52_;
				else
					loc_65_ = loc_56_;
					loc_66_ = loc_52_;
					rt_store_i64(loc_45_, loc_46_, 64, into_bits_i64(1886217512, 2718068))
				end
				loc_52_ = loc_66_;
				loc_56_ = loc_65_;
				loc_65_ = loc_65_[1](bit32_or(loc_46_ + 64, 0), 1356, loc_70_)
				rt_store_i32_into_i8(loc_45_, bit32_or(bit32_or(loc_46_ + 64, 0) + loc_65_, 0), 0, 0)
				loc_68_ = loc_66_[1](loc_68_, loc_70_)
			end
			loc_68_ = loc_67_;
			rt_store_i32(loc_45_, loc_46_, 32, bit32_or(loc_46_ + 64, 0))
			loc_67_ = loc_67_[1](1141, bit32_or(loc_46_ + 32, 0), loc_70_)
			loc_66_ = 2;
			loc_67_ = from_bits_f64(0, 0) --[[ 0_f64 ]];
			loc_65_ = from_bits_f64(0, 1072693248) --[[ 1_f64 ]];
			repeat
				rt_yield_budget = rt_yield_budget - 1
				if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
				loc_67_ = rt_add_f64(loc_67_, rt_divide_f64(from_bits_f64(0, 1072693248) --[[ 1_f64 ]], rt_multiply_f64(loc_65_, loc_65_)));
				if rt_equal_i32(loc_66_, 3000000) then
					loc_64_ = 0;
				else
					loc_63_ = loc_66_;
					loc_64_ = 1;
					loc_66_ = bit32_or(loc_63_ + 2, 0);
					loc_63_ = rt_convert_u32_to_f64(loc_63_);
					loc_67_ = rt_add_f64(loc_67_, rt_divide_f64(from_bits_f64(0, 1072693248) --[[ 1_f64 ]], rt_multiply_f64(loc_63_, loc_63_)));
					loc_65_ = rt_add_f64(loc_65_, from_bits_f64(0, 1073741824) --[[ 2_f64 ]]);
				end
			until loc_64_ == 0
			loc_48_ = loc_69_;
			loc_55_ = loc_68_;
			rt_store_i64(loc_45_, loc_46_, 24, into_bits_i64(1649608659, 1073369510))
			rt_store_f64(loc_45_, loc_46_, 16, loc_67_)
			loc_68_ = loc_68_[1](1318, bit32_or(loc_46_ + 16, 0), loc_70_)
			loc_58_ = loc_69_[1](loc_70_)
			loc_57_ = 0;
			repeat
				rt_yield_budget = rt_yield_budget - 1
				if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
				loc_68_ = loc_48_;
				loc_69_ = loc_58_;
				loc_70_ = loc_47_;
				loc_48_ = loc_68_;
				loc_47_ = loc_49_;
				loc_70_ = loc_68_[1](loc_70_)
				loc_62_ = loc_49_[1](1088, loc_68_)
				loc_61_ = loc_57_;
				loc_58_ = loc_69_;
				loc_70_ = rt_divide_f32(rt_convert_s32_to_f32(bit32_or(loc_70_ - loc_69_, 0)), 1148846080 --[[ 1000_f32 ]]);
				loc_49_ = loc_70_;
				loc_59_ = rt_multiply_f32(loc_70_, 1060320051 --[[ 0.7_f32 ]]);
				loc_57_ = rt_multiply_f32(loc_70_, -1079613850 --[[ -1.3_f32 ]]);
				loc_63_ = 6736;
				loc_64_ = 0;
				repeat
					rt_yield_budget = rt_yield_budget - 1
					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
					loc_67_ = loc_51_;
					loc_69_ = loc_63_;
					loc_70_ = loc_64_;
					loc_51_ = loc_67_;
					loc_68_ = loc_60_;
					loc_67_ = loc_67_[1](rt_add_f32(rt_multiply_f32(rt_convert_u32_to_f32(loc_70_), 1034147594 --[[ 0.08_f32 ]]), loc_57_), loc_68_)
					loc_63_ = 0;
					loc_64_ = loc_69_;
					loc_65_ = loc_70_;
					loc_66_ = 0;
					repeat
						rt_yield_budget = rt_yield_budget - 1
						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
						loc_70_ = loc_60_;
						loc_68_ = loc_51_[1](rt_add_f32(rt_multiply_f32(rt_convert_u32_to_f32(loc_63_), 1031127695 --[[ 0.06_f32 ]]), loc_49_), loc_70_)
						loc_70_ = loc_51_[1](rt_add_f32(rt_multiply_f32(rt_convert_u32_to_f32(bit32_or(loc_65_ + loc_63_, 0)), 1025758986 --[[ 0.04_f32 ]]), loc_59_), loc_70_)
						loc_70_ = rt_add_f32(rt_add_f32(loc_67_, loc_68_), loc_70_);
						loc_70_ = rt_add_f32(loc_70_, loc_70_);
						loc_60_ = loc_51_[1](loc_70_, loc_69_)
						loc_69_ = bit32_or(loc_64_ + loc_66_, 0);
						rt_store_i32_into_i8(loc_45_, loc_69_, 0, rt_saturate_f32_to_u32(rt_add_f32(rt_multiply_f32(loc_60_, 1123024896 --[[ 120_f32 ]]), 1124073472 --[[ 128_f32 ]])))
						loc_68_ = loc_51_[1](rt_add_f32(loc_70_, 1074161254 --[[ 2.1_f32 ]]), loc_68_)
						rt_store_i32_into_i8(loc_45_, bit32_or(loc_69_ + 1, 0), 0, rt_saturate_f32_to_u32(rt_add_f32(rt_multiply_f32(loc_68_, 1123024896 --[[ 120_f32 ]]), 1124073472 --[[ 128_f32 ]])))
						loc_68_ = 255;
						if rt_not_equal_i32(loc_62_, 0) then
							loc_63_, loc_68_ = loc_68_, loc_63_;
							loc_68_, loc_66_ = loc_66_, loc_68_;
						else
							loc_51_, loc_68_ = loc_68_, loc_51_;
							loc_68_, loc_66_ = loc_66_, loc_68_;
							loc_66_, loc_63_ = loc_63_, loc_66_;
							loc_63_, loc_60_ = loc_60_, loc_63_;
							loc_51_ = loc_60_;
							loc_70_ = loc_60_[1](rt_add_f32(loc_70_, 1082549862 --[[ 4.2_f32 ]]), loc_63_)
							loc_63_ = rt_saturate_f32_to_u32(rt_add_f32(rt_multiply_f32(loc_70_, 1123024896 --[[ 120_f32 ]]), 1124073472 --[[ 128_f32 ]]));
						end
						rt_store_i32_into_i8(loc_45_, bit32_or(loc_69_ + 3, 0), 0, 255)
						rt_store_i32_into_i8(loc_45_, bit32_or(loc_69_ + 2, 0), 0, loc_63_)
						loc_63_ = bit32_or(loc_66_ + 1, 0);
						loc_68_ = bit32_or(loc_68_ + 4, 0);
						loc_66_ = loc_68_;
					until not (rt_not_equal_i32(loc_68_, 640))
					loc_63_ = bit32_or(loc_64_ + 640, 0);
					loc_65_ = bit32_or(loc_65_ + 1, 0);
					loc_64_ = loc_65_;
				until not (rt_not_equal_i32(loc_65_, 100))
				loc_50_[1](6736, 160, 100, loc_60_)
				loc_57_ = bit32_or(loc_61_ + 1, 0);
				loc_60_ = rt_remainder_u32(loc_57_, 120);
				loc_61_ = loc_60_;
				if not (rt_not_equal_i32(loc_60_, 0)) then
					loc_60_ = loc_49_;
					loc_49_ = loc_55_;
					loc_55_ = loc_49_;
					rt_store_i32(loc_45_, loc_46_, 0, loc_57_)
					rt_store_f64(loc_45_, loc_46_, 8, rt_widen_f32(loc_60_))
					loc_49_ = loc_49_[1](1162, loc_46_, loc_59_)
				end
				loc_49_ = loc_47_;
				loc_59_ = loc_47_[1](1068, loc_59_)
			until not (rt_equal_i32(loc_59_, 0))
			loc_47_ = loc_43_[1](1078, loc_47_)
			loc_44_[1] = bit32_or(loc_46_ + 128, 0);
			return 0, loc_43_
		end), "i32,i32->i32")
	end)(module_locals[5], module_locals[6], module_locals[7], module_locals[46], module_locals[48], module_locals[53], module_locals[73], module_locals[77], module_locals[83], module_locals[89], module_locals[114], module_locals[3]);
	module_locals[24] = { nil };
	module_locals[24][1] = (function(loc_71_)
		return rt_function_type((function(loc_72_, loc_73_)
			local loc_74_, loc_75_
			loc_75_ = loc_73_;
			loc_71_[1](loc_72_, loc_75_)
			loc_75_ = error('unreachable code');
			return loc_74_
		end), "i32->")
	end)(module_locals[37]);
	module_locals[26] = { nil };
	module_locals[27] = { nil };
	module_locals[106] = { nil };
	module_locals[109] = { nil };
	module_locals[111] = { nil };
	module_locals[25][1] = (function(loc_76_, loc_77_, loc_78_, loc_79_, loc_80_, loc_81_, loc_82_, loc_83_, loc_84_)
		return rt_function_type((function(loc_85_)
			local loc_86_, loc_87_, loc_88_, loc_89_, loc_90_, loc_91_, loc_92_, loc_93_, loc_94_, loc_95_, loc_96_, loc_97_, loc_98_, loc_99_, loc_100_
			loc_100_ = loc_83_[1];
			loc_88_ = loc_83_;
			loc_87_ = bit32_or(loc_100_ - 16, 0);
			loc_88_[1] = loc_87_;
			loc_89_ = loc_84_;
			loc_100_ = loc_85_;
			loc_100_ = loc_79_[1](bit32_or(loc_87_ + 8, 0), bit32_or(loc_87_ + 12, 0), loc_100_)
			if rt_not_equal_i32(loc_100_, 0) then
				loc_86_ = loc_77_;
				loc_90_ = loc_76_;
				loc_92_ = loc_78_;
				loc_93_ = loc_79_;
				loc_94_ = loc_80_;
				loc_95_ = loc_81_;
				loc_96_ = loc_82_;
				loc_91_ = loc_86_;
				loc_86_[1](71, loc_97_)
				loc_97_ = error('unreachable code');
			else
				loc_86_ = loc_77_;
				loc_90_ = loc_76_;
				loc_92_ = loc_78_;
				loc_93_ = loc_79_;
				loc_94_ = loc_80_;
				loc_95_ = loc_81_;
				loc_96_ = loc_82_;
				loc_100_ = buffer_read_i32(loc_89_[1], loc_87_, 8);
				loc_91_ = bit32_or(loc_100_ + 1, 0);
				if rt_equal_i32(loc_91_, 0) then
					loc_91_ = loc_86_;
					loc_86_[1](70, loc_97_)
					loc_97_ = error('unreachable code');
				else
					loc_99_ = buffer_read_i32(loc_89_[1], loc_87_, 12);
					loc_100_ = loc_97_;
					loc_98_ = loc_94_[1](loc_99_, loc_100_)
					if rt_equal_i32(loc_98_, 0) then
						loc_91_ = loc_86_;
						loc_86_[1](70, loc_97_)
						loc_97_ = error('unreachable code');
					else
						loc_100_ = loc_97_;
						loc_99_ = loc_96_[1](loc_91_, 4, loc_100_)
						if rt_equal_i32(loc_99_, 0) then
							loc_97_ = loc_86_;
							loc_86_ = loc_98_;
							loc_98_ = loc_100_;
							loc_95_, loc_99_ = loc_99_, loc_95_;
							loc_91_ = loc_97_;
							loc_95_ = loc_99_;
							loc_99_[1](loc_86_, loc_98_)
							loc_97_[1](70, loc_98_)
							loc_98_ = error('unreachable code');
						else
							loc_97_ = loc_86_;
							loc_86_ = loc_98_;
							loc_98_ = loc_100_;
							loc_95_, loc_99_ = loc_99_, loc_95_;
							loc_100_ = loc_98_;
							loc_98_ = loc_92_[1](loc_95_, loc_86_, loc_100_)
							if rt_not_equal_i32(loc_98_, 0) then
								loc_98_ = loc_97_;
								loc_97_ = loc_95_;
								loc_86_, loc_99_ = loc_99_, loc_86_;
								loc_99_, loc_100_ = loc_100_, loc_99_;
								loc_91_ = loc_98_;
								loc_95_ = loc_86_;
								loc_86_[1](loc_100_, loc_99_)
								loc_86_[1](loc_97_, loc_99_)
								loc_98_[1](71, loc_99_)
								loc_99_ = error('unreachable code');
							else
								loc_98_ = loc_97_;
								loc_97_ = loc_95_;
								loc_95_ = loc_86_;
								loc_86_ = loc_99_;
								loc_99_ = loc_100_;
								loc_100_ = loc_87_;
								loc_87_ = loc_90_;
								loc_90_ = loc_87_;
								loc_91_ = loc_98_;
								loc_95_ = loc_86_;
								loc_98_ = buffer_read_i32(loc_89_[1], loc_100_, 8);
								loc_87_ = loc_87_[1](loc_98_, loc_97_, loc_99_)
								loc_88_[1] = bit32_or(loc_100_ + 16, 0);
							end
						end
					end
				end
			end
			return loc_87_, loc_86_
		end), "->i32")
	end)(module_locals[23], module_locals[24], module_locals[26], module_locals[27], module_locals[106], module_locals[109], module_locals[111], module_locals[114], module_locals[3]);
	module_locals[26][1] = (function(loc_101_)
		return rt_function_type((function(loc_102_, loc_103_, loc_104_)
			local loc_105_, loc_106_
			loc_106_ = loc_104_;
			loc_106_ = loc_101_[1](loc_102_, loc_103_, loc_106_)
			return rt_and_i32(loc_106_, 65535), loc_105_
		end), "i32,i32->i32")
	end)(module_locals[8]);
	module_locals[27][1] = (function(loc_107_)
		return rt_function_type((function(loc_108_, loc_109_, loc_110_)
			local loc_111_, loc_112_
			loc_112_ = loc_110_;
			loc_112_ = loc_107_[1](loc_108_, loc_109_, loc_112_)
			return rt_and_i32(loc_112_, 65535), loc_111_
		end), "i32,i32->i32")
	end)(module_locals[9]);
	module_locals[28] = { nil };
	module_locals[28][1] = (function(loc_113_)
		return rt_function_type((function(loc_114_, loc_115_)
			local loc_116_, loc_117_
			loc_117_ = loc_115_;
			loc_117_ = loc_113_[1](loc_114_, loc_117_)
			return rt_and_i32(loc_117_, 65535), loc_116_
		end), "i32->i32")
	end)(module_locals[10]);
	module_locals[29] = { nil };
	module_locals[29][1] = (function(loc_118_)
		return rt_function_type((function(loc_119_, loc_120_, loc_121_)
			local loc_122_, loc_123_
			loc_123_ = loc_121_;
			loc_123_ = loc_118_[1](loc_119_, loc_120_, loc_123_)
			return rt_and_i32(loc_123_, 65535), loc_122_
		end), "i32,i32->i32")
	end)(module_locals[11]);
	module_locals[30] = { nil };
	module_locals[30][1] = (function(loc_124_)
		return rt_function_type((function(loc_125_, loc_126_, loc_127_)
			local loc_128_, loc_129_
			loc_129_ = loc_127_;
			loc_129_ = loc_124_[1](loc_125_, loc_126_, loc_129_)
			return rt_and_i32(loc_129_, 65535), loc_128_
		end), "i32,i32->i32")
	end)(module_locals[12]);
	module_locals[31] = { nil };
	module_locals[31][1] = (function(loc_130_)
		return rt_function_type((function(loc_131_, loc_132_, loc_133_)
			local loc_134_, loc_135_
			loc_135_ = loc_133_;
			loc_135_ = loc_130_[1](loc_131_, loc_132_, loc_135_)
			return rt_and_i32(loc_135_, 65535), loc_134_
		end), "i32,i32->i32")
	end)(module_locals[13]);
	module_locals[32] = { nil };
	module_locals[32][1] = (function(loc_136_)
		return rt_function_type((function(loc_137_, loc_138_, loc_139_, loc_140_)
			local loc_141_, loc_142_
			loc_142_ = loc_140_;
			loc_142_ = loc_136_[1](loc_137_, loc_138_, loc_139_, loc_142_)
			return rt_and_i32(loc_142_, 65535), loc_141_
		end), "i32,i32,i32->i32")
	end)(module_locals[14]);
	module_locals[33] = { nil };
	module_locals[33][1] = (function(loc_143_)
		return rt_function_type((function(loc_144_, loc_145_, loc_146_, loc_147_, loc_148_)
			local loc_149_, loc_150_
			loc_150_ = loc_148_;
			loc_150_ = loc_143_[1](loc_144_, loc_145_, loc_146_, loc_147_, loc_150_)
			return rt_and_i32(loc_150_, 65535), loc_149_
		end), "i32,i32,i32,i32->i32")
	end)(module_locals[15]);
	module_locals[34] = { nil };
	module_locals[34][1] = (function(loc_151_)
		return rt_function_type((function(loc_152_, loc_153_, loc_154_, loc_155_, loc_156_)
			local loc_157_, loc_158_
			loc_158_ = loc_156_;
			loc_158_ = loc_151_[1](loc_152_, loc_153_, loc_154_, loc_155_, loc_158_)
			return rt_and_i32(loc_158_, 65535), loc_157_
		end), "i32,i64,i32,i32->i32")
	end)(module_locals[16]);
	module_locals[35] = { nil };
	module_locals[35][1] = (function(loc_159_)
		return rt_function_type((function(loc_160_, loc_161_, loc_162_, loc_163_, loc_164_)
			local loc_165_, loc_166_
			loc_166_ = loc_164_;
			loc_166_ = loc_159_[1](loc_160_, loc_161_, loc_162_, loc_163_, loc_166_)
			return rt_and_i32(loc_166_, 65535), loc_165_
		end), "i32,i32,i32,i32->i32")
	end)(module_locals[17]);
	module_locals[36] = { nil };
	module_locals[91] = { nil };
	module_locals[36][1] = (function(loc_167_, loc_168_)
		return rt_function_type((function(loc_169_, loc_170_, loc_171_, loc_172_, loc_173_, loc_174_, loc_175_, loc_176_, loc_177_)
			local loc_178_, loc_179_
			loc_179_ = loc_177_;
			loc_178_ = loc_168_[1](loc_171_, loc_179_)
			loc_179_ = loc_167_[1](loc_169_, loc_170_, loc_171_, loc_178_, loc_172_, loc_173_, loc_174_, loc_175_, loc_176_, loc_179_)
			return rt_and_i32(loc_179_, 65535), loc_178_
		end), "i32,i32,i32,i32,i64,i64,i32,i32->i32")
	end)(module_locals[18], module_locals[91]);
	module_locals[37][1] = (function(loc_180_)
		return rt_function_type((function(loc_181_, loc_182_)
			local loc_183_, loc_184_
			loc_184_ = loc_182_;
			loc_180_[1](loc_181_, loc_184_)
			loc_184_ = error('unreachable code');
			return loc_183_
		end), "i32->")
	end)(module_locals[19]);
	module_locals[38][1] = (function(loc_185_, loc_186_)
		return rt_function_type((function(loc_187_)
			local loc_188_, loc_189_, loc_190_, loc_191_, loc_192_, loc_193_, loc_194_
			rt_store_i32(loc_186_, 0, 70740, 70740)
			loc_190_ = loc_186_;
			loc_194_ = 138000;
			if rt_equal_i32(138000, 0) then
				loc_188_ = loc_187_;
				loc_189_ = loc_185_;
				loc_194_ = loc_189_[1];
				loc_194_ = (rt_greater_than_u32(loc_194_, 1024) and 1 or 0);
				loc_191_ = bit32_or(138000 - 72460, 0);
				loc_193_ = 1024;
				if not (rt_not_equal_i32(loc_194_, 0)) then
					loc_192_ = loc_191_;
					loc_191_ = loc_193_;
				end
				loc_193_ = 138000;
				loc_192_ = 1024;
				if not (rt_not_equal_i32(loc_194_, 0)) then
					loc_193_ = loc_192_;
				end
			else
				loc_188_ = loc_187_;
				loc_189_ = loc_185_;
				loc_193_ = loc_194_;
				loc_191_ = bit32_or(138000 - 72464, 0);
			end
			rt_store_i32(loc_190_, 56, 70740, 0)
			rt_store_i32(loc_190_, 52, 70740, loc_191_)
			rt_store_i32(loc_190_, 48, 70740, loc_193_)
			rt_store_i32(loc_190_, 8, 70740, 70740)
			rt_store_i32(loc_190_, 4, 70740, 70740)
			loc_193_ = buffer_read_i32(loc_190_[1], 0, 70736);
			rt_store_i32(loc_190_, 12, 70740, loc_193_)
			loc_192_ = 0;
			loc_193_ = 8388608;
			if not (rt_less_than_u32(loc_191_, 8388608)) then
				loc_191_ = loc_193_;
			end
			rt_store_i32(loc_190_, loc_192_, 6464, loc_191_)
			return loc_188_
		end), "->")
	end)(module_locals[114], module_locals[3]);
	module_locals[39] = { nil };
	module_locals[39][1] = rt_function_type((function(loc_195_)
		local loc_196_
		loc_196_ = loc_195_;
		return loc_196_
	end), "->");
	module_locals[50] = { nil };
	module_locals[40][1] = (function(loc_197_, loc_198_)
		return rt_function_type((function(loc_199_)
			local loc_200_
			loc_200_ = loc_199_;
			loc_197_[1](loc_200_)
			loc_198_[1](loc_200_)
			return loc_200_
		end), "->")
	end)(module_locals[39], module_locals[50]);
	module_locals[41] = { nil };
	module_locals[41][1] = rt_function_type((function(loc_201_, loc_202_)
		local loc_203_, loc_204_, loc_205_
		loc_205_ = rt_multiply_f64(loc_201_, loc_201_);
		loc_204_ = rt_multiply_f64(loc_201_, loc_205_);
		loc_203_ = loc_202_;
		return rt_narrow_f64(rt_add_f64(rt_multiply_f64(rt_multiply_f64(loc_204_, rt_multiply_f64(loc_205_, loc_205_)), rt_add_f64(rt_multiply_f64(loc_205_, from_bits_f64(2352694951, 1053216135) --[[ 0.000002718311493989822_f64 ]]), from_bits_f64(3804948340, 3207201017) --[[ -0.00019839334836096632_f64 ]])), rt_add_f64(rt_multiply_f64(loc_204_, rt_add_f64(rt_multiply_f64(loc_205_, from_bits_f64(2305751986, 1065423120) --[[ 0.008333329385889463_f64 ]]), from_bits_f64(1422634103, 3217380693) --[[ -0.16666666641626524_f64 ]])), loc_201_))), loc_203_
	end), "f64->f32");
	module_locals[42] = { nil };
	module_locals[42][1] = rt_function_type((function(loc_206_, loc_207_)
		local loc_208_, loc_209_, loc_210_
		loc_210_ = rt_multiply_f64(loc_206_, loc_206_);
		loc_209_ = rt_multiply_f64(loc_210_, loc_210_);
		loc_208_ = loc_207_;
		return rt_narrow_f64(rt_add_f64(rt_multiply_f64(rt_multiply_f64(loc_210_, loc_209_), rt_add_f64(rt_multiply_f64(loc_210_, from_bits_f64(3773714537, 1056543554) --[[ 0.00002439044879627741_f64 ]]), from_bits_f64(3893304871, 3210133639) --[[ -0.001388676377460993_f64 ]])), rt_add_f64(rt_multiply_f64(loc_209_, from_bits_f64(3775216194, 1067799891) --[[ 0.04166662332373906_f64 ]]), rt_add_f64(rt_multiply_f64(loc_210_, from_bits_f64(4245446273, 3219128319) --[[ -0.499999997251031_f64 ]]), from_bits_f64(0, 1072693248) --[[ 1_f64 ]])))), loc_208_
	end), "f64->f32");
	module_locals[43] = { nil };
	module_locals[43][1] = rt_function_type((function(loc_211_, loc_212_, loc_213_)
		local loc_214_, loc_215_, loc_216_, loc_217_
		if rt_less_than_s32(loc_212_, 1024) then
			loc_214_ = loc_213_;
			loc_215_ = loc_212_;
			loc_216_ = loc_211_;
			if not (rt_greater_than_s32(loc_215_, -1023)) then
				loc_217_ = rt_multiply_f64(loc_216_, from_bits_f64(0, 56623104) --[[ 0.0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002004168360008973_f64 ]]);
				if rt_less_than_equal_u32(loc_215_, -1992) then
					loc_216_ = rt_multiply_f64(loc_217_, from_bits_f64(0, 56623104) --[[ 0.0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002004168360008973_f64 ]]);
					loc_217_ = -2960;
					if not (rt_greater_than_u32(loc_215_, -2960)) then
						loc_215_ = loc_217_;
					end
					loc_215_ = bit32_or(loc_215_ + 1938, 0);
				else
					loc_216_ = loc_217_;
					loc_215_ = bit32_or(loc_215_ + 969, 0);
				end
			end
		else
			loc_214_ = loc_213_;
			loc_215_ = loc_212_;
			loc_216_ = loc_211_;
			loc_216_ = rt_multiply_f64(loc_216_, from_bits_f64(0, 2145386496) --[[ 89884656743115800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000_f64 ]]);
			if rt_greater_than_equal_u32(loc_215_, 2047) then
				loc_217_ = loc_215_;
				loc_216_ = rt_multiply_f64(loc_216_, from_bits_f64(0, 2145386496) --[[ 89884656743115800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000_f64 ]]);
				loc_215_ = 3069;
				if not (rt_less_than_u32(loc_217_, 3069)) then
					loc_217_ = loc_215_;
				end
				loc_215_ = bit32_or(loc_217_ + -2046, 0);
			else
				loc_217_ = loc_215_;
				loc_215_ = bit32_or(loc_217_ + -1023, 0);
			end
		end
		return rt_multiply_f64(loc_216_, rt_transmute_i64_to_f64(rt_shift_left_i64(rt_widen_i32(bit32_or(loc_215_ + 1023, 0)), into_bits_i64(52, 0)))), loc_214_
	end), "f64,i32->f64");
	module_locals[44] = { nil };
	module_locals[44][1] = (function(loc_218_, loc_219_, loc_220_)
		return rt_function_type((function(loc_221_, loc_222_, loc_223_, loc_224_, loc_225_, loc_226_)
			local loc_227_, loc_228_, loc_229_, loc_230_, loc_231_, loc_232_, loc_233_, loc_234_, loc_235_, loc_236_, loc_237_, loc_238_, loc_239_, loc_240_, loc_241_, loc_242_, loc_243_, loc_244_, loc_245_, loc_246_, loc_247_, loc_248_, loc_249_, loc_250_, loc_251_, loc_252_, loc_253_, loc_254_, loc_255_, loc_256_, loc_257_, loc_258_, loc_259_, loc_260_, loc_261_, loc_262_, loc_263_, loc_264_, loc_265_, loc_266_
			loc_266_ = loc_219_[1];
			loc_229_ = loc_219_;
			loc_259_ = bit32_or(loc_266_ - 560, 0);
			loc_229_[1] = loc_259_;
			loc_247_ = 0;
			loc_248_ = 0;
			loc_264_ = 0;
			loc_249_ = from_bits_f64(0, 0) --[[ 0_f64 ]];
			loc_228_ = 0;
			loc_235_ = 0;
			loc_241_ = rt_divide_s32(bit32_or(loc_223_ + -3, 0), 24);
			loc_265_ = 0;
			loc_251_ = loc_226_;
			loc_266_ = loc_241_;
			if rt_greater_than_s32(loc_241_, 0) then
				loc_230_ = loc_220_;
				loc_232_ = loc_218_;
				loc_233_ = loc_222_;
				loc_245_ = loc_225_;
				loc_246_ = loc_221_;
				loc_258_ = loc_224_;
				loc_266_ = loc_223_;
			else
				loc_230_ = loc_220_;
				loc_232_ = loc_218_;
				loc_233_ = loc_222_;
				loc_245_ = loc_225_;
				loc_246_ = loc_221_;
				loc_258_ = loc_224_;
				loc_263_ = loc_241_;
				loc_266_ = loc_223_;
				loc_241_ = loc_265_;
			end
			loc_260_ = buffer_read_i32(loc_230_[1], bit32_or(rt_shift_left_i32(loc_245_, 2) + 1424, 0), 0);
			loc_240_ = bit32_or(loc_258_ + -1, 0);
			loc_265_ = bit32_or(loc_260_ + loc_240_, 0);
			loc_266_ = bit32_or(rt_multiply_i32(loc_241_, -24) + loc_266_, 0);
			if not (rt_less_than_s32(loc_265_, 0)) then
				loc_261_ = bit32_or(loc_241_ - loc_240_, 0);
				loc_262_ = bit32_or(loc_260_ + loc_258_, 0);
				loc_263_ = rt_and_i32(loc_262_, 1);
				if rt_equal_i32(loc_265_, 0) then
					loc_265_ = loc_264_;
					loc_264_ = loc_261_;
				else
					loc_257_ = loc_262_;
					loc_265_ = loc_264_;
					loc_264_ = loc_261_;
					loc_261_ = loc_258_;
					loc_265_ = bit32_or(loc_259_ + 320, 0);
					loc_258_ = loc_261_;
					loc_262_ = 0;
					loc_261_ = bit32_or(bit32_or(rt_shift_left_i32(loc_241_, 2) - rt_shift_left_i32(loc_261_, 2), 0) + 1448, 0);
					loc_257_ = rt_and_i32(loc_257_, -2);
					repeat
						rt_yield_budget = rt_yield_budget - 1
						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
						loc_256_ = loc_249_;
						loc_256_ = bit32_or(loc_264_ + loc_262_, 0);
						loc_255_ = from_bits_f64(0, 0) --[[ 0_f64 ]];
						loc_249_ = from_bits_f64(0, 0) --[[ 0_f64 ]];
						if rt_less_than_s32(loc_256_, 0) then
							loc_255_, loc_257_ = loc_257_, loc_255_;
						else
							loc_254_ = loc_249_;
							loc_255_, loc_257_ = loc_257_, loc_255_;
							loc_254_ = buffer_read_i32(loc_230_[1], bit32_or(loc_261_ + -4, 0), 0);
							loc_249_ = rt_convert_s32_to_f64(loc_254_);
						end
						rt_store_f64(loc_230_, loc_265_, 0, loc_249_)
						if not (rt_less_than_s32(loc_256_, -1)) then
							loc_257_ = buffer_read_i32(loc_230_[1], loc_261_, 0);
							loc_257_ = rt_convert_s32_to_f64(loc_257_);
						end
						rt_store_f64(loc_230_, bit32_or(loc_265_ + 8, 0), 0, loc_257_)
						loc_265_ = bit32_or(loc_265_ + 16, 0);
						loc_256_ = bit32_or(loc_262_ + 2, 0);
						loc_262_ = loc_256_;
						loc_261_ = bit32_or(loc_261_ + 8, 0);
						loc_257_ = loc_255_;
					until not (rt_not_equal_i32(loc_255_, loc_256_))
					loc_265_ = loc_262_;
					loc_264_ = bit32_or(loc_264_ + loc_262_, 0);
				end
				if not (rt_equal_i32(loc_263_, 0)) then
					loc_263_ = loc_249_;
					if rt_greater_than_equal_s32(loc_264_, 0) then
						loc_264_ = buffer_read_i32(loc_230_[1], rt_shift_left_i32(loc_264_, 2), 1440);
						loc_249_ = rt_convert_s32_to_f64(loc_264_);
					else
						loc_249_ = from_bits_f64(0, 0) --[[ 0_f64 ]];
					end
					rt_store_f64(loc_230_, bit32_or(bit32_or(loc_259_ + 320, 0) + rt_shift_left_i32(loc_265_, 3), 0), 0, loc_249_)
				end
			end
			loc_262_ = 0;
			loc_243_ = bit32_or(loc_266_ + -24, 0);
			loc_265_ = 0;
			if rt_greater_than_s32(loc_260_, 0) then
				loc_263_ = loc_260_;
			else
				loc_263_ = loc_260_;
				loc_264_ = loc_260_;
				loc_260_ = loc_265_;
			end
			loc_264_ = loc_258_;
			loc_265_ = loc_259_;
			loc_261_ = rt_and_i32(loc_258_, 2147483646);
			loc_259_ = bit32_or(bit32_or(rt_shift_left_i32(loc_258_, 3) + bit32_or(loc_259_ + 320, 0), 0) + -16, 0);
			loc_258_ = rt_and_i32(loc_258_, 1);
			repeat
				rt_yield_budget = rt_yield_budget - 1
				if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
				loc_257_ = loc_249_;
				if rt_greater_than_equal_s32(loc_264_, 1) then
					loc_256_ = loc_262_;
					loc_257_ = loc_260_;
					loc_262_ = 0;
					loc_249_ = from_bits_f64(0, 0) --[[ 0_f64 ]];
					if not (rt_equal_i32(loc_240_, 0)) then
						loc_255_ = loc_246_;
						loc_246_ = loc_255_;
						loc_260_ = loc_259_;
						repeat
							rt_yield_budget = rt_yield_budget - 1
							if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
							loc_253_ = loc_261_;
							loc_242_ = rt_load_f64(loc_230_, bit32_or(loc_255_ + 8, 0), 0);
							loc_244_ = rt_load_f64(loc_230_, loc_260_, 0);
							loc_250_ = rt_load_f64(loc_230_, loc_255_, 0);
							loc_252_ = rt_load_f64(loc_230_, bit32_or(loc_260_ + 8, 0), 0);
							loc_260_ = bit32_or(loc_260_ + -16, 0);
							loc_255_ = bit32_or(loc_255_ + 16, 0);
							loc_254_ = bit32_or(loc_262_ + 2, 0);
							loc_262_ = loc_254_;
							loc_261_ = loc_253_;
							loc_249_ = rt_add_f64(rt_multiply_f64(loc_242_, loc_244_), rt_add_f64(rt_multiply_f64(loc_250_, loc_252_), loc_249_));
						until not (rt_not_equal_i32(loc_253_, loc_254_))
					end
					if not (rt_equal_i32(loc_258_, 0)) then
						loc_260_ = rt_load_f64(loc_230_, bit32_or(loc_246_ + rt_shift_left_i32(loc_262_, 3), 0), 0);
						loc_262_ = rt_load_f64(loc_230_, bit32_or(bit32_or(loc_265_ + 320, 0) + rt_shift_left_i32(bit32_or(bit32_or(loc_256_ + loc_240_, 0) - loc_262_, 0), 3), 0), 0);
						loc_249_ = rt_add_f64(rt_multiply_f64(loc_260_, loc_262_), loc_249_);
					end
				else
					loc_256_ = loc_262_;
					loc_257_ = loc_260_;
					loc_249_ = from_bits_f64(0, 0) --[[ 0_f64 ]];
				end
				rt_store_f64(loc_230_, bit32_or(loc_265_ + rt_shift_left_i32(loc_256_, 3), 0), 0, loc_249_)
				loc_262_ = bit32_or(loc_256_ + 1, 0);
				loc_260_ = loc_257_;
				loc_259_ = bit32_or(loc_259_ + 8, 0);
			until not (rt_not_equal_i32(loc_256_, loc_257_))
			loc_242_ = loc_264_;
			loc_231_ = loc_265_;
			loc_250_ = loc_266_;
			loc_244_ = loc_263_;
			loc_234_ = loc_263_;
			loc_239_ = rt_and_i32(loc_264_, 2147483646);
			loc_238_ = rt_and_i32(loc_264_, 1);
			loc_237_ = bit32_or(47 - loc_266_, 0);
			loc_236_ = bit32_or(48 - loc_266_, 0);
			loc_264_ = bit32_or(bit32_or(loc_265_ + 480, 0) + -4, 0);
			loc_227_ = loc_264_;
			loc_252_ = bit32_or(loc_264_ + rt_shift_left_i32(loc_263_, 2), 0);
			loc_253_ = bit32_or(bit32_or(loc_265_ + 320, 0) + -8, 0);
			loc_254_ = bit32_or(bit32_or(loc_265_ + 480, 0) + -16, 0);
			loc_255_ = bit32_or(loc_265_ + -16, 0);
			loc_256_ = bit32_or(loc_266_ + -25, 0);
			repeat
				rt_yield_budget = rt_yield_budget - 1
				if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
				loc_264_ = loc_235_;
				loc_265_ = loc_228_;
				loc_266_ = loc_249_;
				loc_264_ = rt_shift_left_i32(loc_234_, 3);
				loc_265_ = rt_load_f64(loc_230_, bit32_or(loc_231_ + loc_264_, 0), 0);
				if rt_less_than_s32(loc_234_, 1) then
					loc_257_ = loc_247_;
					loc_266_ = loc_251_;
				else
					loc_257_ = loc_247_;
					loc_266_ = loc_251_;
					loc_262_ = 0;
					if rt_not_equal_i32(loc_234_, 1) then
						loc_261_ = loc_234_;
						loc_263_ = loc_231_;
						loc_264_ = bit32_or(loc_255_ + loc_264_, 0);
						loc_231_ = loc_263_;
						loc_262_ = bit32_or(loc_263_ + 480, 0);
						loc_263_ = 0;
						loc_234_ = loc_261_;
						loc_261_ = rt_and_i32(loc_261_, 2147483646);
						repeat
							rt_yield_budget = rt_yield_budget - 1
							if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
							loc_259_ = loc_261_;
							loc_261_ = rt_convert_s32_to_f64(rt_saturate_f64_to_s32(rt_multiply_f64(loc_265_, from_bits_f64(0, 1047527424) --[[ 0.00000005960464477539063_f64 ]])));
							rt_store_i32(loc_230_, loc_262_, 0, rt_saturate_f64_to_s32(rt_add_f64(rt_multiply_f64(loc_261_, from_bits_f64(0, 3245342720) --[[ -16777216_f64 ]]), loc_265_)))
							loc_265_ = rt_load_f64(loc_230_, bit32_or(loc_264_ + 8, 0), 0);
							loc_265_ = rt_add_f64(loc_265_, loc_261_);
							loc_258_ = rt_convert_s32_to_f64(rt_saturate_f64_to_s32(rt_multiply_f64(loc_265_, from_bits_f64(0, 1047527424) --[[ 0.00000005960464477539063_f64 ]])));
							rt_store_i32(loc_230_, bit32_or(loc_262_ + 4, 0), 0, rt_saturate_f64_to_s32(rt_add_f64(rt_multiply_f64(loc_258_, from_bits_f64(0, 3245342720) --[[ -16777216_f64 ]]), loc_265_)))
							loc_265_ = rt_load_f64(loc_230_, loc_264_, 0);
							loc_264_ = bit32_or(loc_264_ + -16, 0);
							loc_262_ = bit32_or(loc_262_ + 8, 0);
							loc_260_ = bit32_or(loc_263_ + 2, 0);
							loc_263_ = loc_260_;
							loc_261_ = loc_259_;
							loc_265_ = rt_add_f64(loc_265_, loc_258_);
						until not (rt_not_equal_i32(loc_259_, loc_260_))
						loc_264_ = bit32_or(loc_234_ - loc_263_, 0);
					else
						loc_261_ = loc_234_;
						loc_263_ = loc_231_;
						loc_264_ = loc_261_;
						loc_231_ = loc_263_;
						loc_263_ = loc_262_;
						loc_234_ = loc_261_;
					end
					if not (rt_equal_i32(rt_and_i32(loc_234_, 1), 0)) then
						loc_262_ = loc_265_;
						loc_265_ = loc_264_;
						loc_264_ = rt_convert_s32_to_f64(rt_saturate_f64_to_s32(rt_multiply_f64(loc_262_, from_bits_f64(0, 1047527424) --[[ 0.00000005960464477539063_f64 ]])));
						rt_store_i32(loc_230_, bit32_or(bit32_or(loc_231_ + 480, 0) + rt_shift_left_i32(loc_263_, 2), 0), 0, rt_saturate_f64_to_s32(rt_add_f64(rt_multiply_f64(loc_264_, from_bits_f64(0, 3245342720) --[[ -16777216_f64 ]]), loc_262_)))
						loc_265_ = rt_load_f64(loc_230_, bit32_or(bit32_or(rt_shift_left_i32(loc_265_, 3) + loc_231_, 0) + -8, 0), 0);
						loc_265_ = rt_add_f64(loc_265_, loc_264_);
					end
				end
				loc_266_ = loc_232_[1](loc_265_, loc_243_, loc_266_)
				loc_266_ = rt_add_f64(rt_multiply_f64(rt_round_down_f64(rt_multiply_f64(loc_266_, from_bits_f64(0, 1069547520) --[[ 0.125_f64 ]])), from_bits_f64(0, 3223322624) --[[ -8_f64 ]]), loc_266_);
				loc_228_ = rt_saturate_f64_to_s32(loc_266_);
				loc_249_ = rt_subtract_f64(loc_266_, rt_convert_s32_to_f64(loc_228_));
				loc_266_ = (rt_less_than_s32(loc_243_, 1) and 1 or 0);
				if rt_not_equal_i32(loc_266_, 0) then
					if rt_not_equal_i32(loc_243_, 0) then
						loc_235_ = 2;
						if rt_greater_than_equal_f64(loc_249_, from_bits_f64(0, 1071644672) --[[ 0.5_f64 ]]) then
							loc_265_ = 1;
						else
							loc_265_ = loc_235_;
							loc_265_ = 2;
							loc_235_ = 0;
						end
					else
						loc_264_ = buffer_read_i32(loc_230_[1], bit32_or(bit32_or(rt_shift_left_i32(loc_234_, 2) + bit32_or(loc_231_ + 480, 0), 0) + -4, 0), 0);
						loc_265_ = 0;
						loc_235_ = rt_shift_right_s32(loc_264_, 23);
					end
				else
					loc_263_ = loc_237_;
					loc_265_ = bit32_or(bit32_or(rt_shift_left_i32(loc_234_, 2) + bit32_or(loc_231_ + 480, 0), 0) + -4, 0);
					loc_264_ = buffer_read_i32(loc_230_[1], loc_265_, 0);
					loc_262_ = rt_shift_right_s32(loc_264_, loc_236_);
					loc_264_ = bit32_or(loc_264_ - rt_shift_left_i32(loc_262_, loc_236_), 0);
					rt_store_i32(loc_230_, loc_265_, 0, loc_264_)
					loc_265_ = 0;
					loc_237_ = loc_263_;
					loc_228_ = bit32_or(loc_262_ + loc_228_, 0);
					loc_235_ = rt_shift_right_s32(loc_264_, loc_263_);
				end
				if (loc_265_) >= 0 and (loc_265_) < 2 then
					if (loc_265_) < 1 then
						if rt_less_than_s32(loc_235_, 1) then
							loc_265_ = 1;
						else
							loc_265_ = 0;
						end
					else
						loc_265_ = 0;
					end
				else
					loc_265_ = 1;
				end
				if not (rt_not_equal_i32(loc_265_, 0)) then
					loc_265_ = loc_266_;
					loc_266_ = 1;
					if rt_less_than_s32(loc_234_, 1) then
						loc_264_ = loc_265_;
						loc_265_ = loc_228_;
					else
						loc_264_ = loc_265_;
						loc_265_ = loc_228_;
						loc_266_ = 1;
						loc_263_ = 0;
						loc_262_ = rt_and_i32(loc_234_, 1);
						if not (rt_equal_i32(loc_234_, 1)) then
							loc_259_ = loc_234_;
							loc_261_ = bit32_or(loc_231_ + 480, 0);
							loc_263_ = 0;
							loc_234_ = loc_259_;
							loc_260_ = 0;
							loc_259_ = rt_and_i32(loc_259_, 2147483646);
							repeat
								rt_yield_budget = rt_yield_budget - 1
								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
								loc_266_ = buffer_read_i32(loc_230_[1], loc_261_, 0);
								if rt_equal_i32(loc_260_, 0) then
									loc_247_ = loc_259_;
									if rt_equal_i32(loc_266_, 0) then
										loc_259_ = 1;
										loc_260_ = 1;
									else
										loc_259_ = 0;
										loc_260_ = 16777216;
									end
								else
									loc_247_ = loc_259_;
									loc_259_ = 0;
									loc_260_ = 16777215;
								end
								if not (rt_not_equal_i32(loc_259_, 0)) then
									rt_store_i32(loc_230_, loc_261_, 0, bit32_or(loc_260_ - loc_266_, 0))
									loc_260_ = 0;
								end
								loc_259_ = bit32_or(loc_261_ + 4, 0);
								loc_266_ = buffer_read_i32(loc_230_[1], loc_259_, 0);
								if rt_not_equal_i32(loc_260_, 0) then
									if rt_equal_i32(loc_266_, 0) then
										loc_258_ = 1;
										loc_266_ = 1;
										loc_260_ = 0;
									else
										loc_258_ = 0;
										loc_260_ = 16777216;
									end
								else
									loc_258_ = 0;
									loc_260_ = 16777215;
								end
								if not (rt_not_equal_i32(loc_258_, 0)) then
									rt_store_i32(loc_230_, loc_259_, 0, bit32_or(loc_260_ - loc_266_, 0))
									loc_266_ = 0;
									loc_260_ = 1;
								end
								loc_261_ = bit32_or(loc_261_ + 8, 0);
								loc_258_ = bit32_or(loc_263_ + 2, 0);
								loc_263_ = loc_258_;
								loc_259_ = loc_247_;
							until not (rt_not_equal_i32(loc_247_, loc_258_))
						end
						if not (rt_equal_i32(loc_262_, 0)) then
							loc_262_ = bit32_or(bit32_or(loc_231_ + 480, 0) + rt_shift_left_i32(loc_263_, 2), 0);
							loc_263_ = buffer_read_i32(loc_230_[1], loc_262_, 0);
							if rt_not_equal_i32(loc_266_, 0) then
								if rt_equal_i32(loc_263_, 0) then
									loc_261_ = 1;
									loc_266_ = 1;
								else
									loc_261_ = 0;
									loc_266_ = 16777216;
								end
							else
								loc_261_ = 0;
								loc_266_ = 16777215;
							end
							if not (rt_not_equal_i32(loc_261_, 0)) then
								rt_store_i32(loc_230_, loc_262_, 0, bit32_or(loc_266_ - loc_263_, 0))
								loc_266_ = 0;
							end
						end
					end
					if not (rt_not_equal_i32(loc_264_, 0)) then
						loc_264_ = 8388607;
						if (loc_256_) >= 0 and (loc_256_) < 2 then
							if (loc_256_) < 1 then
								loc_263_ = 0;
							else
								loc_263_ = 0;
								loc_264_ = 4194303;
							end
						else
							loc_263_ = 1;
						end
						if not (rt_not_equal_i32(loc_263_, 0)) then
							loc_262_ = bit32_or(bit32_or(rt_shift_left_i32(loc_234_, 2) + bit32_or(loc_231_ + 480, 0), 0) + -4, 0);
							loc_263_ = buffer_read_i32(loc_230_[1], loc_262_, 0);
							rt_store_i32(loc_230_, loc_262_, 0, rt_and_i32(loc_263_, loc_264_))
						end
					end
					loc_228_ = bit32_or(loc_265_ + 1, 0);
					if not (rt_not_equal_i32(loc_235_, 2)) then
						loc_265_ = loc_235_;
						loc_249_ = rt_subtract_f64(from_bits_f64(0, 1072693248) --[[ 1_f64 ]], loc_249_);
						loc_235_ = 2;
						if not (rt_not_equal_i32(rt_and_i32(loc_266_, 1), 0)) then
							loc_265_ = loc_232_;
							loc_232_ = loc_265_;
							loc_266_ = loc_251_;
							loc_266_ = loc_265_[1](from_bits_f64(0, 1072693248) --[[ 1_f64 ]], loc_243_, loc_266_)
							loc_249_ = rt_subtract_f64(loc_249_, loc_266_);
						end
					end
				end
				if rt_not_equal_f64(loc_249_, from_bits_f64(0, 0) --[[ 0_f64 ]]) then
					loc_257_ = 0;
					loc_248_ = 1;
				else
					if rt_less_than_equal_s32(loc_234_, loc_244_) then
						loc_266_ = 0;
					else
						loc_263_ = bit32_or(loc_234_ - loc_244_, 0);
						loc_266_ = 0;
						loc_265_ = rt_and_i32(loc_263_, 3);
						if rt_greater_than_u32(bit32_or(loc_244_ - loc_234_, 0), -4) then
							loc_264_ = loc_234_;
						else
							loc_262_ = loc_263_;
							loc_263_ = loc_234_;
							loc_264_ = loc_234_;
							loc_263_ = bit32_or(loc_254_ + rt_shift_left_i32(loc_264_, 2), 0);
							loc_266_ = 0;
							loc_234_ = loc_264_;
							loc_262_ = rt_and_i32(loc_262_, -4);
							repeat
								rt_yield_budget = rt_yield_budget - 1
								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
								loc_258_ = buffer_read_i32(loc_230_[1], loc_263_, 0);
								loc_259_ = buffer_read_i32(loc_230_[1], bit32_or(loc_263_ + 4, 0), 0);
								loc_260_ = buffer_read_i32(loc_230_[1], bit32_or(loc_263_ + 8, 0), 0);
								loc_261_ = buffer_read_i32(loc_230_[1], bit32_or(loc_263_ + 12, 0), 0);
								loc_263_ = bit32_or(loc_263_ + -16, 0);
								loc_266_ = rt_or_i32(loc_258_, rt_or_i32(loc_259_, rt_or_i32(loc_260_, rt_or_i32(loc_261_, loc_266_))));
								loc_261_ = bit32_or(loc_262_ + -4, 0);
								loc_262_ = loc_261_;
								loc_264_ = bit32_or(loc_264_ + -4, 0);
							until loc_261_ == 0
						end
						if not (rt_equal_i32(loc_265_, 0)) then
							loc_264_, loc_265_ = loc_265_, loc_264_;
							loc_265_ = bit32_or(loc_227_ + rt_shift_left_i32(loc_265_, 2), 0);
							repeat
								rt_yield_budget = rt_yield_budget - 1
								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
								loc_263_ = buffer_read_i32(loc_230_[1], loc_265_, 0);
								loc_265_ = bit32_or(loc_265_ + -4, 0);
								loc_266_ = rt_or_i32(loc_263_, loc_266_);
								loc_263_ = bit32_or(loc_264_ + -1, 0);
								loc_264_ = loc_263_;
							until loc_263_ == 0
						end
						if rt_equal_i32(loc_266_, 0) then
							loc_266_ = 0;
						else
							loc_265_ = loc_248_;
							loc_266_ = loc_257_;
							loc_266_ = 1;
							loc_257_ = 0;
							loc_248_ = 0;
						end
					end
					if not (rt_not_equal_i32(loc_266_, 0)) then
						loc_265_ = loc_248_;
						loc_266_ = loc_257_;
						loc_264_ = loc_252_;
						loc_265_ = loc_242_;
						loc_266_ = loc_234_;
						repeat
							rt_yield_budget = rt_yield_budget - 1
							if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
							loc_263_ = buffer_read_i32(loc_230_[1], loc_264_, 0);
							loc_264_ = bit32_or(loc_264_ + -4, 0);
							loc_234_ = bit32_or(loc_234_ + 1, 0);
						until not (rt_equal_i32(loc_263_, 0))
						loc_242_ = loc_265_;
						loc_257_ = loc_266_;
						loc_248_ = bit32_or(loc_253_ + rt_shift_left_i32(bit32_or(loc_265_ + loc_266_, 0), 3), 0);
						repeat
							rt_yield_budget = rt_yield_budget - 1
							if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
							loc_266_ = loc_249_;
							loc_258_ = bit32_or(loc_257_ + 1, 0);
							loc_265_ = buffer_read_i32(loc_230_[1], bit32_or(rt_shift_left_i32(bit32_or(loc_258_ + loc_241_, 0), 2) + 1440, 0), 0);
							loc_266_ = bit32_or(loc_257_ + loc_242_, 0);
							rt_store_f64(loc_230_, bit32_or(bit32_or(loc_231_ + 320, 0) + rt_shift_left_i32(loc_266_, 3), 0), 0, rt_convert_s32_to_f64(loc_265_))
							if rt_greater_than_equal_s32(loc_242_, 1) then
								loc_247_ = loc_234_;
								loc_234_ = loc_266_;
								loc_257_ = 0;
								loc_249_ = from_bits_f64(0, 0) --[[ 0_f64 ]];
								if not (rt_equal_i32(loc_240_, 0)) then
									loc_266_ = loc_246_;
									loc_246_ = loc_266_;
									loc_259_ = loc_248_;
									loc_260_ = loc_266_;
									repeat
										rt_yield_budget = rt_yield_budget - 1
										if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
										loc_262_ = loc_239_;
										loc_266_ = rt_load_f64(loc_230_, bit32_or(loc_260_ + 8, 0), 0);
										loc_265_ = rt_load_f64(loc_230_, loc_259_, 0);
										loc_264_ = rt_load_f64(loc_230_, loc_260_, 0);
										loc_263_ = rt_load_f64(loc_230_, bit32_or(loc_259_ + 8, 0), 0);
										loc_259_ = bit32_or(loc_259_ + -16, 0);
										loc_260_ = bit32_or(loc_260_ + 16, 0);
										loc_261_ = bit32_or(loc_257_ + 2, 0);
										loc_257_ = loc_261_;
										loc_239_ = loc_262_;
										loc_249_ = rt_add_f64(rt_multiply_f64(loc_266_, loc_265_), rt_add_f64(rt_multiply_f64(loc_264_, loc_263_), loc_249_));
									until not (rt_not_equal_i32(loc_262_, loc_261_))
								end
								if not (rt_equal_i32(loc_238_, 0)) then
									loc_259_ = loc_234_;
									loc_234_ = rt_load_f64(loc_230_, bit32_or(loc_246_ + rt_shift_left_i32(loc_257_, 3), 0), 0);
									loc_257_ = rt_load_f64(loc_230_, bit32_or(bit32_or(loc_231_ + 320, 0) + rt_shift_left_i32(bit32_or(loc_259_ - loc_257_, 0), 3), 0), 0);
									loc_249_ = rt_add_f64(rt_multiply_f64(loc_234_, loc_257_), loc_249_);
								end
							else
								loc_247_ = loc_234_;
								loc_249_ = from_bits_f64(0, 0) --[[ 0_f64 ]];
							end
							rt_store_f64(loc_230_, bit32_or(loc_231_ + rt_shift_left_i32(loc_258_, 3), 0), 0, loc_249_)
							loc_257_ = loc_258_;
							loc_248_ = bit32_or(loc_248_ + 8, 0);
							loc_234_ = loc_247_;
						until not (rt_less_than_s32(loc_258_, loc_247_))
						loc_257_ = 1;
						loc_248_ = 65535;
					end
				end
				loc_247_ = loc_257_;
			until loc_257_ == 0
			if rt_not_equal_i32(loc_248_, 0) then
				loc_251_ = loc_232_[1](loc_249_, bit32_or(24 - loc_250_, 0), loc_251_)
				if rt_equal_i32((rt_greater_than_equal_f64(loc_251_, from_bits_f64(0, 1097859072) --[[ 16777216_f64 ]]) and 1 or 0), 0) then
					loc_251_ = rt_saturate_f64_to_s32(loc_251_);
				else
					loc_249_ = loc_251_;
					loc_251_ = loc_243_;
					loc_251_ = rt_saturate_f64_to_s32(rt_multiply_f64(loc_249_, from_bits_f64(0, 1047527424) --[[ 0.00000005960464477539063_f64 ]]));
					rt_store_i32(loc_230_, bit32_or(bit32_or(loc_231_ + 480, 0) + rt_shift_left_i32(loc_234_, 2), 0), 0, rt_saturate_f64_to_s32(rt_add_f64(rt_multiply_f64(rt_convert_s32_to_f64(loc_251_), from_bits_f64(0, 3245342720) --[[ -16777216_f64 ]]), loc_249_)))
					loc_234_ = bit32_or(loc_234_ + 1, 0);
					loc_243_ = loc_250_;
				end
				rt_store_i32(loc_230_, bit32_or(bit32_or(loc_231_ + 480, 0) + rt_shift_left_i32(loc_234_, 2), 0), 0, loc_251_)
			else
				loc_250_, loc_251_ = loc_251_, loc_250_;
				loc_251_ = bit32_or(bit32_or(bit32_or(loc_231_ + 480, 0) + rt_shift_left_i32(loc_234_, 2), 0) + -4, 0);
				loc_227_ = loc_250_;
				repeat
					rt_yield_budget = rt_yield_budget - 1
					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
					loc_250_ = buffer_read_i32(loc_230_[1], loc_251_, 0);
					loc_251_ = bit32_or(loc_251_ + -4, 0);
					loc_234_ = bit32_or(loc_234_ + -1, 0);
					loc_243_ = bit32_or(loc_243_ + -24, 0);
				until not (rt_equal_i32(loc_250_, 0))
			end
			if not (rt_less_than_s32(loc_234_, 0)) then
				loc_251_ = loc_227_;
				loc_248_ = loc_232_[1](from_bits_f64(0, 1072693248) --[[ 1_f64 ]], loc_243_, loc_251_)
				if rt_equal_i32(rt_and_i32(loc_234_, 1), 0) then
					loc_243_ = loc_244_;
					loc_250_ = loc_231_;
					loc_251_ = loc_234_;
					loc_249_ = buffer_read_i32(loc_230_[1], bit32_or(bit32_or(loc_250_ + 480, 0) + rt_shift_left_i32(loc_251_, 2), 0), 0);
					rt_store_f64(loc_230_, bit32_or(loc_250_ + rt_shift_left_i32(loc_251_, 3), 0), 0, rt_multiply_f64(loc_248_, rt_convert_s32_to_f64(loc_249_)))
					loc_249_ = bit32_or(loc_251_ + -1, 0);
					loc_248_ = rt_multiply_f64(loc_248_, from_bits_f64(0, 1047527424) --[[ 0.00000005960464477539063_f64 ]]);
				else
					loc_243_ = loc_244_;
					loc_250_ = loc_231_;
					loc_251_ = loc_234_;
					loc_249_ = loc_251_;
				end
				if not (rt_equal_i32(loc_251_, 0)) then
					loc_246_ = loc_248_;
					loc_247_ = loc_249_;
					loc_248_ = loc_250_;
					loc_249_ = bit32_or(bit32_or(rt_shift_left_i32(loc_247_, 2) + bit32_or(loc_248_ + 480, 0), 0) + -4, 0);
					loc_250_ = loc_248_;
					loc_248_ = bit32_or(bit32_or(rt_shift_left_i32(loc_247_, 3) + loc_248_, 0) + -8, 0);
					loc_247_ = bit32_or(loc_247_ + 1, 0);
					repeat
						rt_yield_budget = rt_yield_budget - 1
						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
						loc_242_ = loc_246_;
						loc_244_ = buffer_read_i32(loc_230_[1], loc_249_, 0);
						loc_246_ = rt_multiply_f64(loc_242_, from_bits_f64(0, 1047527424) --[[ 0.00000005960464477539063_f64 ]]);
						rt_store_f64(loc_230_, loc_248_, 0, rt_multiply_f64(loc_246_, rt_convert_s32_to_f64(loc_244_)))
						loc_244_ = buffer_read_i32(loc_230_[1], bit32_or(loc_249_ + 4, 0), 0);
						rt_store_f64(loc_230_, bit32_or(loc_248_ + 8, 0), 0, rt_multiply_f64(loc_242_, rt_convert_s32_to_f64(loc_244_)))
						loc_249_ = bit32_or(loc_249_ + -8, 0);
						loc_248_ = bit32_or(loc_248_ + -16, 0);
						loc_244_ = bit32_or(loc_247_ + -2, 0);
						loc_247_ = loc_244_;
						loc_246_ = rt_multiply_f64(loc_246_, from_bits_f64(0, 1047527424) --[[ 0.00000005960464477539063_f64 ]]);
					until loc_244_ == 0
				end
				loc_244_ = loc_251_;
				loc_231_ = loc_250_;
				loc_234_ = loc_251_;
				loc_242_ = bit32_or(loc_250_ + rt_shift_left_i32(loc_251_, 3), 0);
				repeat
					rt_yield_budget = rt_yield_budget - 1
					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
					loc_251_ = bit32_or(loc_234_ - loc_244_, 0);
					if rt_less_than_s32(loc_243_, loc_251_) then
						loc_238_ = loc_243_;
						loc_240_ = loc_251_;
						loc_241_ = loc_244_;
					else
						loc_240_ = loc_251_;
						loc_241_ = loc_244_;
						loc_250_ = loc_243_;
						loc_238_ = loc_251_;
					end
					if rt_greater_than_equal_s32(loc_238_, 0) then
						if rt_not_equal_i32(loc_238_, 0) then
							loc_237_ = 0;
							loc_239_ = 0;
							loc_236_ = rt_and_i32(bit32_or(loc_238_ + 1, 0), -2);
							loc_244_ = from_bits_f64(0, 0) --[[ 0_f64 ]];
							repeat
								rt_yield_budget = rt_yield_budget - 1
								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
								loc_247_ = loc_236_;
								loc_251_ = rt_load_f64(loc_230_, bit32_or(loc_237_ + 4216, 0), 0);
								loc_248_ = bit32_or(loc_242_ + loc_237_, 0);
								loc_250_ = rt_load_f64(loc_230_, bit32_or(loc_248_ + 8, 0), 0);
								loc_249_ = rt_load_f64(loc_230_, bit32_or(loc_237_ + 4208, 0), 0);
								loc_248_ = rt_load_f64(loc_230_, loc_248_, 0);
								loc_237_ = bit32_or(loc_237_ + 16, 0);
								loc_246_ = bit32_or(loc_239_ + 2, 0);
								loc_239_ = loc_246_;
								loc_236_ = loc_247_;
								loc_244_ = rt_add_f64(rt_multiply_f64(loc_251_, loc_250_), rt_add_f64(rt_multiply_f64(loc_249_, loc_248_), loc_244_));
							until not (rt_not_equal_i32(loc_247_, loc_246_))
						else
							loc_239_ = 0;
							loc_244_ = from_bits_f64(0, 0) --[[ 0_f64 ]];
						end
						if not (rt_not_equal_i32(rt_and_i32(loc_238_, 1), 0)) then
							loc_238_ = rt_load_f64(loc_230_, rt_shift_left_i32(loc_239_, 3), 4208);
							loc_239_ = rt_load_f64(loc_230_, bit32_or(loc_231_ + rt_shift_left_i32(bit32_or(loc_239_ + loc_241_, 0), 3), 0), 0);
							loc_244_ = rt_add_f64(rt_multiply_f64(loc_238_, loc_239_), loc_244_);
						end
					else
						loc_251_ = loc_238_;
						loc_244_ = from_bits_f64(0, 0) --[[ 0_f64 ]];
					end
					rt_store_f64(loc_230_, bit32_or(bit32_or(loc_231_ + 160, 0) + rt_shift_left_i32(loc_240_, 3), 0), 0, loc_244_)
					loc_244_ = bit32_or(loc_241_ + -1, 0);
					loc_242_ = bit32_or(loc_242_ + -8, 0);
				until not (rt_greater_than_s32(loc_241_, 0))
			end
			if (loc_245_) >= 0 and (loc_245_) < 4 then
				if (loc_245_) < 2 then
					if (loc_245_) < 1 then
						if rt_greater_than_equal_s32(loc_234_, 0) then
							loc_244_ = loc_233_;
							if rt_not_equal_i32(rt_and_i32(loc_234_, 3), 3) then
								loc_242_ = bit32_or(bit32_or(loc_231_ + 160, 0) + rt_shift_left_i32(loc_234_, 3), 0);
								loc_245_ = loc_234_;
								loc_241_ = rt_and_i32(bit32_or(loc_234_ + 1, 0), 3);
								loc_243_ = from_bits_f64(0, 0) --[[ 0_f64 ]];
								repeat
									rt_yield_budget = rt_yield_budget - 1
									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
									loc_239_ = rt_load_f64(loc_230_, loc_242_, 0);
									loc_242_ = bit32_or(loc_242_ + -8, 0);
									loc_245_ = bit32_or(loc_245_ + -1, 0);
									loc_240_ = bit32_or(loc_241_ + -1, 0);
									loc_241_ = loc_240_;
									loc_243_ = rt_add_f64(loc_243_, loc_239_);
								until loc_240_ == 0
							else
								loc_245_ = loc_234_;
								loc_243_ = from_bits_f64(0, 0) --[[ 0_f64 ]];
							end
							if not (rt_less_than_u32(loc_234_, 3)) then
								loc_242_ = loc_245_;
								loc_245_ = bit32_or(bit32_or(rt_shift_left_i32(loc_242_, 3) + bit32_or(loc_231_ + 160, 0), 0) + -24, 0);
								loc_242_ = bit32_or(loc_242_ + 1, 0);
								repeat
									rt_yield_budget = rt_yield_budget - 1
									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
									loc_237_ = rt_load_f64(loc_230_, bit32_or(loc_245_ + 24, 0), 0);
									loc_238_ = rt_load_f64(loc_230_, bit32_or(loc_245_ + 16, 0), 0);
									loc_239_ = rt_load_f64(loc_230_, bit32_or(loc_245_ + 8, 0), 0);
									loc_240_ = rt_load_f64(loc_230_, loc_245_, 0);
									loc_245_ = bit32_or(loc_245_ + -32, 0);
									loc_241_ = bit32_or(loc_242_ + -4, 0);
									loc_242_ = loc_241_;
									loc_243_ = rt_add_f64(rt_add_f64(rt_add_f64(rt_add_f64(loc_243_, loc_237_), loc_238_), loc_239_), loc_240_);
								until loc_241_ == 0
							end
						else
							loc_244_ = loc_233_;
							loc_243_ = from_bits_f64(0, 0) --[[ 0_f64 ]];
						end
						loc_245_ = rt_negate_f64(loc_243_);
						if rt_not_equal_i32(loc_235_, 0) then
							loc_233_ = loc_244_;
						else
							loc_233_ = loc_244_;
							loc_245_ = loc_243_;
						end
						rt_store_f64(loc_230_, loc_244_, 0, loc_245_)
						loc_245_ = 1;
					else
						loc_245_ = 0;
					end
				elseif (loc_245_) > 2 then
					loc_245_ = from_bits_f64(0, 0) --[[ 0_f64 ]];
					if not (rt_less_than_s32(loc_234_, 1)) then
						loc_240_ = bit32_or(bit32_or(loc_231_ + 160, 0) + rt_shift_left_i32(loc_234_, 3), 0);
						loc_241_ = rt_load_f64(loc_230_, loc_240_, 0);
						if rt_not_equal_i32(rt_and_i32(loc_234_, 1), 0) then
							loc_244_ = bit32_or(loc_234_ + -1, 0);
							loc_239_ = bit32_or(bit32_or(loc_231_ + 160, 0) + rt_shift_left_i32(loc_244_, 3), 0);
							loc_242_ = rt_load_f64(loc_230_, loc_239_, 0);
							loc_243_ = rt_add_f64(loc_242_, loc_241_);
							rt_store_f64(loc_230_, loc_239_, 0, loc_243_)
							rt_store_f64(loc_230_, loc_240_, 0, rt_add_f64(loc_241_, rt_subtract_f64(loc_242_, loc_243_)))
						else
							loc_244_ = loc_240_;
							loc_244_ = loc_234_;
							loc_243_ = loc_241_;
						end
						if not (rt_equal_i32(loc_234_, 1)) then
							loc_242_ = loc_243_;
							loc_243_ = loc_244_;
							loc_244_ = bit32_or(bit32_or(rt_shift_left_i32(loc_243_, 3) + bit32_or(loc_231_ + 160, 0), 0) + -16, 0);
							loc_243_ = bit32_or(loc_243_ + 1, 0);
							repeat
								rt_yield_budget = rt_yield_budget - 1
								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
								loc_237_ = loc_242_;
								loc_239_ = rt_load_f64(loc_230_, loc_244_, 0);
								loc_240_ = bit32_or(loc_244_ + 8, 0);
								loc_238_ = rt_load_f64(loc_230_, loc_240_, 0);
								loc_241_ = rt_add_f64(loc_238_, loc_237_);
								loc_242_ = rt_add_f64(loc_239_, loc_241_);
								rt_store_f64(loc_230_, loc_244_, 0, loc_242_)
								rt_store_f64(loc_230_, bit32_or(loc_244_ + 16, 0), 0, rt_add_f64(loc_237_, rt_subtract_f64(loc_238_, loc_241_)))
								rt_store_f64(loc_230_, loc_240_, 0, rt_add_f64(loc_241_, rt_subtract_f64(loc_239_, loc_242_)))
								loc_244_ = bit32_or(loc_244_ + -16, 0);
								loc_241_ = bit32_or(loc_243_ + -2, 0);
								loc_243_ = loc_241_;
							until not (rt_greater_than_u32(loc_241_, 1))
							if not (rt_equal_i32(loc_234_, 1)) then
								loc_245_ = bit32_or(bit32_or(loc_231_ + 160, 0) + rt_shift_left_i32(loc_234_, 3), 0);
								loc_243_ = rt_load_f64(loc_230_, loc_245_, 0);
								loc_245_ = bit32_or(loc_245_ + -8, 0);
								loc_244_ = bit32_or(loc_234_ + 1, 0);
								repeat
									rt_yield_budget = rt_yield_budget - 1
									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
									loc_241_ = loc_243_;
									loc_242_ = rt_load_f64(loc_230_, loc_245_, 0);
									loc_243_ = rt_add_f64(loc_242_, loc_241_);
									rt_store_f64(loc_230_, loc_245_, 0, loc_243_)
									rt_store_f64(loc_230_, bit32_or(loc_245_ + 8, 0), 0, rt_add_f64(loc_241_, rt_subtract_f64(loc_242_, loc_243_)))
									loc_245_ = bit32_or(loc_245_ + -8, 0);
									loc_242_ = bit32_or(loc_244_ + -1, 0);
									loc_244_ = loc_242_;
								until not (rt_greater_than_u32(loc_242_, 2))
								loc_244_ = bit32_or(bit32_or(loc_231_ + 160, 0) + rt_shift_left_i32(loc_234_, 3), 0);
								loc_243_ = bit32_or(loc_234_ + 1, 0);
								loc_245_ = from_bits_f64(0, 0) --[[ 0_f64 ]];
								repeat
									rt_yield_budget = rt_yield_budget - 1
									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
									loc_241_ = rt_load_f64(loc_230_, loc_244_, 0);
									loc_244_ = bit32_or(loc_244_ + -8, 0);
									loc_242_ = bit32_or(loc_243_ + -1, 0);
									loc_243_ = loc_242_;
									loc_245_ = rt_add_f64(loc_245_, loc_241_);
								until not (rt_greater_than_u32(loc_242_, 2))
							end
						end
					end
					loc_244_ = rt_load_f64(loc_230_, loc_231_, 160);
					if rt_not_equal_i32(loc_235_, 0) then
						rt_store_f64(loc_230_, loc_233_, 0, rt_negate_f64(loc_244_))
						rt_store_f64(loc_230_, loc_233_, 16, rt_negate_f64(loc_245_))
						loc_245_ = rt_load_f64(loc_230_, loc_231_, 168);
						rt_store_f64(loc_230_, loc_233_, 8, rt_negate_f64(loc_245_))
						loc_245_ = 1;
					else
						rt_store_f64(loc_230_, loc_233_, 0, loc_244_)
						rt_store_f64(loc_230_, loc_233_, 16, loc_245_)
						loc_245_ = rt_load_f64(loc_230_, loc_231_, 168);
						rt_store_f64(loc_230_, loc_233_, 8, loc_245_)
						loc_245_ = 1;
					end
				else
					loc_245_ = 0;
				end
			else
				loc_245_ = 1;
			end
			if not (rt_not_equal_i32(loc_245_, 0)) then
				if rt_greater_than_equal_s32(loc_234_, 0) then
					loc_236_ = loc_235_;
					loc_237_ = loc_234_;
					loc_243_ = loc_233_;
					if rt_not_equal_i32(rt_and_i32(loc_237_, 3), 3) then
						loc_244_ = bit32_or(bit32_or(loc_231_ + 160, 0) + rt_shift_left_i32(loc_237_, 3), 0);
						loc_245_ = loc_237_;
						loc_241_ = rt_and_i32(bit32_or(loc_237_ + 1, 0), 3);
						loc_242_ = from_bits_f64(0, 0) --[[ 0_f64 ]];
						repeat
							rt_yield_budget = rt_yield_budget - 1
							if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
							loc_239_ = rt_load_f64(loc_230_, loc_244_, 0);
							loc_244_ = bit32_or(loc_244_ + -8, 0);
							loc_245_ = bit32_or(loc_245_ + -1, 0);
							loc_240_ = bit32_or(loc_241_ + -1, 0);
							loc_241_ = loc_240_;
							loc_242_ = rt_add_f64(loc_242_, loc_239_);
						until loc_240_ == 0
					else
						loc_245_ = loc_237_;
						loc_242_ = from_bits_f64(0, 0) --[[ 0_f64 ]];
					end
					if not (rt_less_than_u32(loc_237_, 3)) then
						loc_244_ = loc_245_;
						loc_245_ = bit32_or(bit32_or(rt_shift_left_i32(loc_244_, 3) + bit32_or(loc_231_ + 160, 0), 0) + -24, 0);
						loc_244_ = bit32_or(loc_244_ + 1, 0);
						repeat
							rt_yield_budget = rt_yield_budget - 1
							if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
							loc_235_ = rt_load_f64(loc_230_, bit32_or(loc_245_ + 24, 0), 0);
							loc_238_ = rt_load_f64(loc_230_, bit32_or(loc_245_ + 16, 0), 0);
							loc_239_ = rt_load_f64(loc_230_, bit32_or(loc_245_ + 8, 0), 0);
							loc_240_ = rt_load_f64(loc_230_, loc_245_, 0);
							loc_245_ = bit32_or(loc_245_ + -32, 0);
							loc_241_ = bit32_or(loc_244_ + -4, 0);
							loc_244_ = loc_241_;
							loc_242_ = rt_add_f64(rt_add_f64(rt_add_f64(rt_add_f64(loc_242_, loc_235_), loc_238_), loc_239_), loc_240_);
						until loc_241_ == 0
					end
				else
					loc_236_ = loc_235_;
					loc_237_ = loc_234_;
					loc_243_ = loc_233_;
					loc_242_ = from_bits_f64(0, 0) --[[ 0_f64 ]];
				end
				loc_245_ = rt_negate_f64(loc_242_);
				if rt_not_equal_i32(loc_236_, 0) then
					loc_234_ = loc_243_;
					loc_244_ = loc_242_;
				else
					loc_234_ = loc_243_;
					loc_244_ = loc_242_;
					loc_245_ = loc_242_;
				end
				rt_store_f64(loc_230_, loc_243_, 0, loc_245_)
				loc_245_ = rt_load_f64(loc_230_, loc_231_, 160);
				loc_235_ = 1;
				loc_233_ = rt_subtract_f64(loc_245_, loc_244_);
				if not (rt_less_than_s32(loc_237_, 1)) then
					loc_245_ = rt_and_i32(loc_237_, 3);
					if rt_less_than_u32(bit32_or(loc_237_ + -1, 0), 3) then
						loc_239_ = loc_237_;
						loc_237_ = loc_235_;
						loc_235_ = loc_245_;
					else
						loc_244_ = loc_235_;
						loc_235_ = loc_245_;
						loc_245_ = loc_237_;
						loc_238_ = bit32_or(bit32_or(loc_231_ + 160, 0) + 32, 0);
						loc_239_ = 0;
						loc_237_ = rt_and_i32(loc_245_, 2147483644);
						repeat
							rt_yield_budget = rt_yield_budget - 1
							if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
							loc_241_ = loc_237_;
							loc_245_ = rt_load_f64(loc_230_, bit32_or(loc_238_ + -24, 0), 0);
							loc_244_ = rt_load_f64(loc_230_, bit32_or(loc_238_ + -16, 0), 0);
							loc_243_ = rt_load_f64(loc_230_, bit32_or(loc_238_ + -8, 0), 0);
							loc_242_ = rt_load_f64(loc_230_, loc_238_, 0);
							loc_238_ = bit32_or(loc_238_ + 32, 0);
							loc_240_ = bit32_or(loc_239_ + 4, 0);
							loc_239_ = loc_240_;
							loc_237_ = loc_241_;
							loc_233_ = rt_add_f64(rt_add_f64(rt_add_f64(rt_add_f64(loc_233_, loc_245_), loc_244_), loc_243_), loc_242_);
						until not (rt_not_equal_i32(loc_241_, loc_240_))
						loc_237_ = bit32_or(loc_239_ + 1, 0);
					end
					if not (rt_equal_i32(loc_235_, 0)) then
						loc_237_ = bit32_or(bit32_or(loc_231_ + 160, 0) + rt_shift_left_i32(loc_237_, 3), 0);
						repeat
							rt_yield_budget = rt_yield_budget - 1
							if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
							loc_239_ = rt_load_f64(loc_230_, loc_237_, 0);
							loc_237_ = bit32_or(loc_237_ + 8, 0);
							loc_238_ = bit32_or(loc_235_ + -1, 0);
							loc_235_ = loc_238_;
							loc_233_ = rt_add_f64(loc_233_, loc_239_);
						until loc_238_ == 0
					end
				end
				loc_235_ = rt_negate_f64(loc_233_);
				if not (rt_not_equal_i32(loc_236_, 0)) then
					loc_235_ = loc_233_;
				end
				rt_store_f64(loc_230_, loc_234_, 8, loc_235_)
			end
			loc_229_[1] = bit32_or(loc_231_ + 560, 0);
			return rt_and_i32(loc_228_, 7), loc_227_
		end), "i32,i32,i32,i32,i32->i32")
	end)(module_locals[43], module_locals[114], module_locals[3]);
	module_locals[45] = { nil };
	module_locals[45][1] = (function(loc_267_, loc_268_, loc_269_)
		return rt_function_type((function(loc_270_, loc_271_, loc_272_)
			local loc_273_, loc_274_, loc_275_, loc_276_, loc_277_, loc_278_, loc_279_, loc_280_, loc_281_
			loc_281_ = loc_268_[1];
			loc_275_ = loc_268_;
			loc_277_ = bit32_or(loc_281_ - 16, 0);
			loc_275_[1] = loc_277_;
			loc_281_ = rt_transmute_f32_to_i32(loc_270_);
			loc_273_ = rt_and_i32(loc_281_, 2147483647);
			if rt_greater_than_u32(loc_273_, 1305022426) then
				loc_274_ = loc_270_;
				loc_276_ = loc_269_;
				loc_278_ = loc_267_;
				loc_279_ = loc_272_;
				loc_280_ = loc_271_;
				if rt_less_than_u32(loc_273_, 2139095040) then
					loc_274_ = bit32_or(rt_shift_right_u32(loc_273_, 23) + -150, 0);
					rt_store_f64(loc_276_, loc_277_, 8, rt_widen_f32(rt_transmute_i32_to_f32(bit32_or(loc_273_ - rt_shift_left_i32(loc_274_, 23), 0))))
					loc_274_ = loc_278_[1](bit32_or(loc_277_ + 8, 0), loc_277_, loc_274_, 1, 0, loc_279_)
					loc_279_ = rt_load_f64(loc_276_, loc_277_, 0);
					if rt_greater_than_s32(loc_281_, -1) then
						rt_store_f64(loc_276_, loc_280_, 0, loc_279_)
					else
						rt_store_f64(loc_276_, loc_280_, 0, rt_negate_f64(loc_279_))
						loc_274_ = bit32_or(0 - loc_274_, 0);
					end
				else
					rt_store_f64(loc_276_, loc_280_, 0, rt_widen_f32(rt_subtract_f32(loc_274_, loc_274_)))
					loc_274_ = 0;
					loc_273_ = loc_279_;
				end
			else
				loc_274_ = loc_270_;
				loc_276_ = loc_269_;
				loc_278_ = loc_267_;
				loc_279_ = loc_272_;
				loc_280_ = loc_271_;
				loc_274_ = rt_widen_f32(loc_274_);
				loc_281_ = rt_add_f64(rt_add_f64(rt_multiply_f64(loc_274_, from_bits_f64(1841940611, 1071931184) --[[ 0.6366197723675814_f64 ]]), from_bits_f64(0, 1127743488) --[[ 6755399441055744_f64 ]]), from_bits_f64(0, 3275227136) --[[ -6755399441055744_f64 ]]);
				rt_store_f64(loc_276_, loc_280_, 0, rt_add_f64(rt_add_f64(loc_274_, rt_multiply_f64(loc_281_, from_bits_f64(1342177280, 3220775419) --[[ -1.5707963109016418_f64 ]])), rt_multiply_f64(loc_281_, from_bits_f64(1629119075, 3192983732) --[[ -0.000000015893254773528196_f64 ]])))
				loc_274_ = rt_saturate_f64_to_s32(loc_281_);
				loc_273_ = loc_279_;
			end
			loc_275_[1] = bit32_or(loc_277_ + 16, 0);
			return loc_274_, loc_273_
		end), "f32,i32->i32")
	end)(module_locals[44], module_locals[114], module_locals[3]);
	module_locals[46][1] = (function(loc_282_, loc_283_, loc_284_, loc_285_, loc_286_)
		return rt_function_type((function(loc_287_, loc_288_)
			local loc_289_, loc_290_, loc_291_, loc_292_, loc_293_, loc_294_, loc_295_, loc_296_, loc_297_, loc_298_, loc_299_
			loc_299_ = loc_285_[1];
			loc_291_ = loc_285_;
			loc_293_ = bit32_or(loc_299_ - 16, 0);
			loc_291_[1] = loc_293_;
			loc_289_ = rt_transmute_f32_to_i32(loc_287_);
			loc_297_ = rt_and_i32(loc_289_, 2147483647);
			if rt_greater_than_u32(loc_297_, 1061752794) then
				loc_290_ = loc_287_;
				loc_292_ = loc_286_;
				loc_294_ = loc_282_;
				loc_295_ = loc_283_;
				loc_296_ = loc_284_;
				loc_298_ = loc_288_;
				if rt_greater_than_u32(loc_297_, 1081824209) then
					if rt_greater_than_u32(loc_297_, 1088565717) then
						if rt_less_than_u32(loc_297_, 2139095040) then
							loc_298_ = loc_296_[1](loc_290_, bit32_or(loc_293_ + 8, 0), loc_298_)
							loc_297_ = rt_load_f64(loc_292_, loc_293_, 8);
							loc_298_ = rt_and_i32(loc_298_, 3);
							if (loc_298_) >= 0 and (loc_298_) < 4 then
								if (loc_298_) < 2 then
									if (loc_298_) < 1 then
										loc_298_ = 0;
									else
										loc_298_ = loc_290_;
										loc_290_ = loc_295_;
										loc_295_ = loc_290_;
										loc_298_ = loc_289_;
										loc_290_ = loc_290_[1](loc_297_, loc_298_)
										loc_298_ = 1;
									end
								elseif (loc_298_) > 2 then
									loc_298_ = loc_290_;
									loc_290_ = loc_295_;
									loc_295_ = loc_290_;
									loc_298_ = loc_289_;
									loc_290_ = loc_290_[1](loc_297_, loc_298_)
									loc_298_ = 1;
									loc_290_ = rt_negate_f32(loc_290_);
								else
									loc_298_ = loc_290_;
									loc_290_ = loc_294_;
									loc_294_ = loc_290_;
									loc_298_ = loc_289_;
									loc_290_ = loc_290_[1](rt_negate_f64(loc_297_), loc_298_)
									loc_298_ = 1;
								end
							else
								loc_298_ = 0;
							end
							if not (rt_not_equal_i32(loc_298_, 0)) then
								loc_289_, loc_294_ = loc_294_, loc_289_;
								loc_294_, loc_290_ = loc_290_, loc_294_;
								loc_294_ = loc_289_;
								loc_290_ = loc_289_[1](loc_297_, loc_290_)
							end
						else
							loc_290_ = rt_subtract_f32(loc_290_, loc_290_);
							loc_289_ = loc_298_;
						end
					else
						if rt_greater_than_u32(loc_297_, 1085271519) then
							loc_299_ = loc_289_;
							loc_289_ = loc_294_;
							loc_297_ = from_bits_f64(1413754136, 1075388923) --[[ 6.283185307179586_f64 ]];
							loc_294_ = from_bits_f64(1413754136, 3222872571) --[[ -6.283185307179586_f64 ]];
							if not (rt_less_than_s32(loc_299_, 0)) then
								loc_297_ = loc_294_;
							end
							loc_294_ = loc_289_;
							loc_290_ = loc_289_[1](rt_add_f64(loc_297_, rt_widen_f32(loc_290_)), loc_298_)
						else
							loc_297_ = loc_298_;
							loc_299_ = loc_289_;
							loc_289_ = loc_294_;
							loc_298_ = rt_widen_f32(loc_290_);
							if rt_greater_than_s32(loc_299_, -1) then
								loc_294_ = loc_289_;
								loc_299_ = loc_297_;
								loc_297_ = loc_295_;
								loc_295_ = loc_297_;
								loc_299_ = loc_297_[1](rt_add_f64(loc_298_, from_bits_f64(2134057426, 3222460796) --[[ -4.71238898038469_f64 ]]), loc_299_)
								loc_290_ = rt_negate_f32(loc_299_);
							else
								loc_294_ = loc_289_;
								loc_299_ = loc_297_;
								loc_297_ = loc_295_;
								loc_295_ = loc_297_;
								loc_290_ = loc_297_[1](rt_add_f64(loc_298_, from_bits_f64(2134057426, 1074977148) --[[ 4.71238898038469_f64 ]]), loc_299_)
							end
						end
					end
				else
					loc_299_ = loc_297_;
					loc_297_ = rt_widen_f32(loc_290_);
					if rt_greater_than_u32(loc_299_, 1075235811) then
						loc_290_ = loc_294_;
						loc_299_ = loc_298_;
						loc_298_ = from_bits_f64(1413754136, 3221823995) --[[ -3.141592653589793_f64 ]];
						loc_294_ = from_bits_f64(1413754136, 1074340347) --[[ 3.141592653589793_f64 ]];
						if not (rt_greater_than_s32(loc_289_, -1)) then
							loc_298_ = loc_294_;
						end
						loc_294_ = loc_290_;
						loc_290_ = loc_290_[1](rt_negate_f64(rt_add_f64(loc_298_, loc_297_)), loc_299_)
					else
						loc_290_ = loc_294_;
						loc_299_ = loc_298_;
						if rt_greater_than_s32(loc_289_, -1) then
							loc_294_ = loc_290_;
							loc_298_ = loc_297_;
							loc_297_ = loc_295_;
							loc_295_ = loc_297_;
							loc_290_ = loc_297_[1](rt_add_f64(loc_298_, from_bits_f64(1413754136, 3220775419) --[[ -1.5707963267948966_f64 ]]), loc_299_)
						else
							loc_294_ = loc_290_;
							loc_298_ = loc_297_;
							loc_297_ = loc_295_;
							loc_295_ = loc_297_;
							loc_299_ = loc_297_[1](rt_add_f64(loc_298_, from_bits_f64(1413754136, 1073291771) --[[ 1.5707963267948966_f64 ]]), loc_299_)
							loc_290_ = rt_negate_f32(loc_299_);
						end
					end
				end
			else
				loc_290_ = loc_287_;
				loc_292_ = loc_286_;
				loc_294_ = loc_282_;
				loc_295_ = loc_283_;
				loc_296_ = loc_284_;
				loc_298_ = loc_288_;
				loc_299_ = loc_289_;
				if rt_less_than_u32(loc_297_, 964689920) then
					loc_289_ = loc_298_;
				else
					loc_289_ = loc_298_;
					loc_298_ = loc_294_;
					loc_294_ = loc_298_;
					loc_299_ = loc_289_;
					loc_290_ = loc_298_[1](rt_widen_f32(loc_290_), loc_299_)
				end
			end
			loc_291_[1] = bit32_or(loc_293_ + 16, 0);
			return loc_290_, loc_289_
		end), "f32->f32")
	end)(module_locals[41], module_locals[42], module_locals[45], module_locals[114], module_locals[3]);
	module_locals[47] = { nil };
	module_locals[47][1] = rt_function_type((function(loc_300_, loc_301_)
		local loc_302_
		loc_302_ = loc_301_;
		return loc_302_
	end), "i32->");
	module_locals[49] = { nil };
	module_locals[74] = { nil };
	module_locals[75] = { nil };
	module_locals[112] = rt_table_new({ }, 6, 6);
	module_locals[48][1] = (function(loc_303_, loc_304_, loc_305_, loc_306_, loc_307_, loc_308_, loc_309_)
		return rt_function_type((function(loc_310_, loc_311_)
			local loc_312_, loc_313_, loc_314_, loc_315_, loc_316_, loc_317_, loc_318_, loc_319_, loc_320_, loc_321_, loc_322_, loc_323_, loc_324_, loc_325_
			loc_315_ = loc_308_;
			loc_316_ = loc_309_;
			loc_325_ = loc_311_;
			loc_314_ = loc_304_[1](loc_310_, loc_325_)
			loc_324_ = buffer_read_i32(loc_316_[1], loc_310_, 12);
			loc_324_ = rt_table_get_function(loc_315_, loc_324_, "i32->i32");
			loc_313_ = loc_324_(loc_310_, loc_325_)
			loc_325_ = rt_load_i32_from_u8(loc_316_, loc_310_, 0);
			if rt_not_equal_i32(rt_and_i32(loc_325_, 1), 0) then
				loc_317_ = loc_303_;
				loc_318_ = loc_304_;
				loc_319_ = loc_305_;
				loc_320_ = loc_306_;
				loc_321_ = loc_307_;
				loc_322_ = loc_310_;
			else
				loc_317_ = loc_303_;
				loc_318_ = loc_304_;
				loc_319_ = loc_305_;
				loc_320_ = loc_306_;
				loc_321_ = loc_307_;
				loc_322_ = loc_310_;
				loc_325_ = loc_312_;
				loc_317_[1](loc_322_, loc_325_)
				loc_312_ = loc_319_[1](loc_325_)
				loc_323_ = buffer_read_i32(loc_316_[1], loc_322_, 52);
				loc_325_ = buffer_read_i32(loc_316_[1], loc_322_, 48);
				if rt_equal_i32(loc_325_, 0) then
					loc_312_, loc_322_ = loc_322_, loc_312_;
					loc_322_, loc_320_ = loc_320_, loc_322_;
					loc_320_, loc_323_ = loc_323_, loc_320_;
					loc_323_, loc_321_ = loc_321_, loc_323_;
				else
					loc_312_, loc_322_ = loc_322_, loc_312_;
					loc_322_, loc_320_ = loc_320_, loc_322_;
					loc_320_, loc_323_ = loc_323_, loc_320_;
					loc_323_, loc_321_ = loc_321_, loc_323_;
					rt_store_i32(loc_316_, loc_325_, 52, loc_320_)
				end
				if not (rt_equal_i32(loc_320_, 0)) then
					rt_store_i32(loc_316_, loc_320_, 48, loc_325_)
				end
				loc_325_ = buffer_read_i32(loc_316_[1], loc_321_, 0);
				if not (rt_not_equal_i32(loc_325_, loc_312_)) then
					rt_store_i32(loc_316_, loc_321_, 0, loc_320_)
				end
				loc_320_ = loc_322_;
				loc_321_ = loc_323_;
				loc_322_[1](loc_324_)
				loc_324_ = buffer_read_i32(loc_316_[1], loc_312_, 80);
				loc_323_[1](loc_324_, loc_322_)
				loc_323_[1](loc_312_, loc_322_)
			end
			return rt_or_i32(loc_313_, loc_314_), loc_312_
		end), "i32->i32")
	end)(module_locals[47], module_locals[49], module_locals[74], module_locals[75], module_locals[109], module_locals[112], module_locals[3]);
	module_locals[49][1] = (function(loc_326_, loc_327_, loc_328_, loc_329_, loc_330_)
		return rt_function_type((function(loc_331_, loc_332_)
			local loc_333_, loc_334_, loc_335_, loc_336_, loc_337_, loc_338_, loc_339_, loc_340_, loc_341_, loc_342_, loc_343_
			if rt_not_equal_i32(loc_331_, 0) then
				loc_333_ = loc_332_;
				loc_334_ = loc_331_;
				loc_335_ = loc_329_;
				loc_336_ = loc_330_;
				loc_337_ = loc_326_;
				loc_338_ = loc_327_;
				loc_339_ = loc_328_;
				loc_341_ = buffer_read_i32(loc_336_[1], loc_334_, 20);
				loc_342_ = buffer_read_i32(loc_336_[1], loc_334_, 24);
				if rt_equal_i32(loc_341_, loc_342_) then
					loc_342_ = 0;
				else
					loc_342_ = buffer_read_i32(loc_336_[1], loc_334_, 32);
					loc_341_ = rt_table_get_function(loc_335_, loc_342_, "i32,i32,i32->i32");
					loc_342_ = loc_333_;
					loc_342_ = loc_341_(loc_334_, 0, 0, loc_342_)
					loc_342_ = buffer_read_i32(loc_336_[1], loc_334_, 20);
					if rt_not_equal_i32(loc_342_, 0) then
						loc_342_ = 0;
					else
						loc_342_ = loc_334_;
						loc_342_ = 1;
						loc_334_ = -1;
					end
				end
				if not (rt_not_equal_i32(loc_342_, 0)) then
					loc_340_ = buffer_read_i32(loc_336_[1], loc_334_, 4);
					loc_341_ = buffer_read_i32(loc_336_[1], loc_334_, 8);
					if not (rt_equal_i32(loc_340_, loc_341_)) then
						loc_342_ = buffer_read_i32(loc_336_[1], loc_334_, 36);
						loc_342_ = rt_table_get_function(loc_335_, loc_342_, "i32,i64,i32->i64");
						loc_341_ = loc_342_(loc_334_, rt_extend_s32_to_i64(rt_widen_i32(bit32_or(loc_340_ - loc_341_, 0))), 1, loc_333_)
					end
					rt_store_i32(loc_336_, loc_334_, 24, 0)
					rt_store_i64(loc_336_, loc_334_, 16, into_bits_i64(0, 0))
					rt_store_i64(loc_336_, loc_334_, 4, into_bits_i64(0, 0))
					loc_334_ = 0;
				end
			else
				loc_333_ = loc_332_;
				loc_335_ = loc_329_;
				loc_336_ = loc_330_;
				loc_337_ = loc_326_;
				loc_338_ = loc_327_;
				loc_339_ = loc_328_;
				loc_343_ = loc_331_;
				loc_343_ = buffer_read_i32(loc_336_[1], 0, 6584);
				loc_334_ = 0;
				if rt_equal_i32(loc_343_, 0) then
					loc_341_ = loc_339_;
					loc_343_ = loc_333_;
				else
					loc_340_ = loc_337_;
					loc_341_ = loc_339_;
					loc_342_ = loc_334_;
					loc_343_ = loc_333_;
					loc_337_ = loc_340_;
					loc_342_ = buffer_read_i32(loc_336_[1], 0, 6584);
					loc_334_ = loc_340_[1](loc_342_, loc_343_)
				end
				loc_342_ = buffer_read_i32(loc_336_[1], 0, 6704);
				if not (rt_equal_i32(loc_342_, 0)) then
					loc_340_ = loc_337_;
					loc_337_ = loc_340_;
					loc_342_ = buffer_read_i32(loc_336_[1], 0, 6704);
					loc_342_ = loc_340_[1](loc_342_, loc_343_)
					loc_334_ = rt_or_i32(loc_342_, loc_334_);
				end
				loc_343_ = loc_338_[1](loc_343_)
				loc_340_ = buffer_read_i32(loc_336_[1], loc_343_, 0);
				if not (rt_equal_i32(loc_340_, 0)) then
					repeat
						rt_yield_budget = rt_yield_budget - 1
						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
						loc_339_ = buffer_read_i32(loc_336_[1], loc_340_, 20);
						loc_343_ = buffer_read_i32(loc_336_[1], loc_340_, 24);
						if not (rt_equal_i32(loc_339_, loc_343_)) then
							loc_343_ = loc_342_;
							loc_342_ = buffer_read_i32(loc_336_[1], loc_340_, 32);
							loc_342_ = rt_table_get_function(loc_335_, loc_342_, "i32,i32,i32->i32");
							loc_343_ = loc_342_(loc_340_, 0, 0, loc_343_)
							loc_343_ = buffer_read_i32(loc_336_[1], loc_340_, 20);
							if rt_not_equal_i32(loc_343_, 0) then
								loc_339_ = buffer_read_i32(loc_336_[1], loc_340_, 4);
								loc_333_ = buffer_read_i32(loc_336_[1], loc_340_, 8);
								if not (rt_equal_i32(loc_339_, loc_333_)) then
									loc_343_ = buffer_read_i32(loc_336_[1], loc_340_, 36);
									loc_343_ = rt_table_get_function(loc_335_, loc_343_, "i32,i64,i32->i64");
									loc_339_ = loc_343_(loc_340_, rt_extend_s32_to_i64(rt_widen_i32(bit32_or(loc_339_ - loc_333_, 0))), 1, loc_342_)
								end
								rt_store_i32(loc_336_, loc_340_, 24, 0)
								rt_store_i64(loc_336_, loc_340_, 16, into_bits_i64(0, 0))
								rt_store_i64(loc_336_, loc_340_, 4, into_bits_i64(0, 0))
								loc_339_ = 0;
							else
								loc_339_ = -1;
							end
							loc_334_ = rt_or_i32(loc_339_, loc_334_);
						end
						loc_339_ = buffer_read_i32(loc_336_[1], loc_340_, 52);
						loc_340_ = loc_339_;
					until loc_339_ == 0
				end
				loc_339_ = loc_341_;
				loc_341_[1](loc_342_)
			end
			return loc_334_, loc_333_
		end), "i32->i32")
	end)(module_locals[49], module_locals[74], module_locals[75], module_locals[112], module_locals[3]);
	module_locals[50][1] = (function(loc_344_, loc_345_, loc_346_)
		return rt_function_type((function(loc_347_)
			local loc_348_, loc_349_, loc_350_, loc_351_, loc_352_, loc_353_, loc_354_, loc_355_
			loc_349_ = loc_345_;
			loc_350_ = loc_346_;
			loc_355_ = loc_347_;
			loc_355_ = loc_344_[1](loc_355_)
			loc_355_ = buffer_read_i32(loc_350_[1], loc_355_, 0);
			if rt_equal_i32(loc_355_, 0) then
				loc_351_ = loc_344_;
			else
				loc_351_ = loc_344_;
				repeat
					rt_yield_budget = rt_yield_budget - 1
					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
					loc_353_ = buffer_read_i32(loc_350_[1], loc_355_, 20);
					loc_354_ = buffer_read_i32(loc_350_[1], loc_355_, 24);
					if not (rt_equal_i32(loc_353_, loc_354_)) then
						loc_354_ = buffer_read_i32(loc_350_[1], loc_355_, 32);
						loc_353_ = rt_table_get_function(loc_349_, loc_354_, "i32,i32,i32->i32");
						loc_354_ = loc_348_;
						loc_354_ = loc_353_(loc_355_, 0, 0, loc_354_)
					end
					loc_354_ = buffer_read_i32(loc_350_[1], loc_355_, 4);
					loc_353_ = buffer_read_i32(loc_350_[1], loc_355_, 8);
					if not (rt_equal_i32(loc_354_, loc_353_)) then
						loc_352_ = loc_348_;
						loc_348_ = buffer_read_i32(loc_350_[1], loc_355_, 36);
						loc_348_ = rt_table_get_function(loc_349_, loc_348_, "i32,i64,i32->i64");
						loc_354_ = loc_348_(loc_355_, rt_extend_s32_to_i64(rt_widen_i32(bit32_or(loc_354_ - loc_353_, 0))), 1, loc_352_)
					end
					loc_354_ = buffer_read_i32(loc_350_[1], loc_355_, 52);
					loc_355_ = loc_354_;
				until loc_354_ == 0
			end
			loc_355_ = buffer_read_i32(loc_350_[1], 0, 70848);
			if not (rt_equal_i32(loc_355_, 0)) then
				loc_353_ = buffer_read_i32(loc_350_[1], loc_355_, 20);
				loc_354_ = buffer_read_i32(loc_350_[1], loc_355_, 24);
				if not (rt_equal_i32(loc_353_, loc_354_)) then
					loc_354_ = buffer_read_i32(loc_350_[1], loc_355_, 32);
					loc_353_ = rt_table_get_function(loc_349_, loc_354_, "i32,i32,i32->i32");
					loc_354_ = loc_348_;
					loc_354_ = loc_353_(loc_355_, 0, 0, loc_354_)
				end
				loc_354_ = buffer_read_i32(loc_350_[1], loc_355_, 4);
				loc_353_ = buffer_read_i32(loc_350_[1], loc_355_, 8);
				if not (rt_equal_i32(loc_354_, loc_353_)) then
					loc_352_ = loc_348_;
					loc_348_ = buffer_read_i32(loc_350_[1], loc_355_, 36);
					loc_348_ = rt_table_get_function(loc_349_, loc_348_, "i32,i64,i32->i64");
					loc_355_ = loc_348_(loc_355_, rt_extend_s32_to_i64(rt_widen_i32(bit32_or(loc_354_ - loc_353_, 0))), 1, loc_352_)
				end
			end
			loc_355_ = buffer_read_i32(loc_350_[1], 0, 6584);
			if not (rt_equal_i32(loc_355_, 0)) then
				loc_353_ = buffer_read_i32(loc_350_[1], loc_355_, 20);
				loc_354_ = buffer_read_i32(loc_350_[1], loc_355_, 24);
				if not (rt_equal_i32(loc_353_, loc_354_)) then
					loc_354_ = buffer_read_i32(loc_350_[1], loc_355_, 32);
					loc_353_ = rt_table_get_function(loc_349_, loc_354_, "i32,i32,i32->i32");
					loc_354_ = loc_348_;
					loc_354_ = loc_353_(loc_355_, 0, 0, loc_354_)
				end
				loc_354_ = buffer_read_i32(loc_350_[1], loc_355_, 4);
				loc_353_ = buffer_read_i32(loc_350_[1], loc_355_, 8);
				if not (rt_equal_i32(loc_354_, loc_353_)) then
					loc_352_ = loc_348_;
					loc_348_ = buffer_read_i32(loc_350_[1], loc_355_, 36);
					loc_348_ = rt_table_get_function(loc_349_, loc_348_, "i32,i64,i32->i64");
					loc_355_ = loc_348_(loc_355_, rt_extend_s32_to_i64(rt_widen_i32(bit32_or(loc_354_ - loc_353_, 0))), 1, loc_352_)
				end
			end
			loc_352_ = buffer_read_i32(loc_350_[1], 0, 6704);
			if not (rt_equal_i32(loc_352_, 0)) then
				loc_354_ = buffer_read_i32(loc_350_[1], loc_352_, 20);
				loc_355_ = buffer_read_i32(loc_350_[1], loc_352_, 24);
				if not (rt_equal_i32(loc_354_, loc_355_)) then
					loc_355_ = buffer_read_i32(loc_350_[1], loc_352_, 32);
					loc_354_ = rt_table_get_function(loc_349_, loc_355_, "i32,i32,i32->i32");
					loc_355_ = loc_348_;
					loc_355_ = loc_354_(loc_352_, 0, 0, loc_355_)
				end
				loc_353_ = buffer_read_i32(loc_350_[1], loc_352_, 4);
				loc_354_ = buffer_read_i32(loc_350_[1], loc_352_, 8);
				if not (rt_equal_i32(loc_353_, loc_354_)) then
					loc_355_ = buffer_read_i32(loc_350_[1], loc_352_, 36);
					loc_355_ = rt_table_get_function(loc_349_, loc_355_, "i32,i64,i32->i64");
					loc_354_ = loc_355_(loc_352_, rt_extend_s32_to_i64(rt_widen_i32(bit32_or(loc_353_ - loc_354_, 0))), 1, loc_348_)
				end
			end
			return loc_348_
		end), "->")
	end)(module_locals[74], module_locals[112], module_locals[3]);
	module_locals[51] = { nil };
	module_locals[51][1] = (function(loc_356_, loc_357_)
		return rt_function_type((function(loc_358_, loc_359_)
			local loc_360_, loc_361_, loc_362_, loc_363_, loc_364_, loc_365_, loc_366_
			loc_366_ = buffer_read_i32(loc_357_[1], loc_358_, 60);
			loc_363_ = loc_357_;
			rt_store_i32(loc_363_, loc_358_, 60, rt_or_i32(bit32_or(loc_366_ + -1, 0), loc_366_))
			loc_365_ = buffer_read_i32(loc_363_[1], loc_358_, 20);
			loc_366_ = buffer_read_i32(loc_363_[1], loc_358_, 24);
			if rt_equal_i32(loc_365_, loc_366_) then
				loc_360_ = loc_359_;
				loc_362_ = loc_356_;
				loc_365_ = loc_358_;
			else
				loc_360_ = loc_359_;
				loc_362_ = loc_356_;
				loc_365_ = loc_358_;
				loc_366_ = buffer_read_i32(loc_363_[1], loc_365_, 32);
				loc_364_ = rt_table_get_function(loc_362_, loc_366_, "i32,i32,i32->i32");
				loc_366_ = loc_360_;
				loc_366_ = loc_364_(loc_365_, 0, 0, loc_366_)
			end
			rt_store_i32(loc_363_, loc_365_, 24, 0)
			rt_store_i64(loc_363_, loc_365_, 16, into_bits_i64(0, 0))
			loc_361_ = buffer_read_i32(loc_363_[1], loc_365_, 0);
			if rt_equal_i32(rt_and_i32(loc_361_, 4), 0) then
				loc_366_ = buffer_read_i32(loc_363_[1], loc_365_, 40);
				loc_364_ = buffer_read_i32(loc_363_[1], loc_365_, 44);
				loc_364_ = bit32_or(loc_366_ + loc_364_, 0);
				rt_store_i32(loc_363_, loc_365_, 8, loc_364_)
				rt_store_i32(loc_363_, loc_365_, 4, loc_364_)
				loc_361_ = rt_shift_right_s32(rt_shift_left_i32(loc_361_, 27), 31);
			else
				rt_store_i32(loc_363_, loc_365_, 0, rt_or_i32(loc_361_, 32))
				loc_361_ = -1;
			end
			return loc_361_, loc_360_
		end), "i32->i32")
	end)(module_locals[112], module_locals[3]);
	module_locals[52] = { nil };
	module_locals[52][1] = (function(loc_367_, loc_368_, loc_369_, loc_370_)
		return rt_function_type((function(loc_371_, loc_372_)
			local loc_373_, loc_374_, loc_375_, loc_376_, loc_377_, loc_378_, loc_379_, loc_380_, loc_381_
			loc_381_ = loc_368_[1];
			loc_375_ = loc_368_;
			loc_378_ = bit32_or(loc_381_ - 16, 0);
			loc_375_[1] = loc_378_;
			loc_376_ = loc_369_;
			loc_377_ = loc_370_;
			loc_381_ = loc_372_;
			loc_381_ = loc_367_[1](loc_371_, loc_381_)
			loc_374_ = -1;
			if rt_not_equal_i32(loc_381_, 0) then
				loc_379_ = loc_367_;
				loc_380_ = loc_371_;
			else
				loc_379_ = loc_367_;
				loc_380_ = loc_371_;
				loc_381_ = buffer_read_i32(loc_377_[1], loc_380_, 28);
				loc_381_ = rt_table_get_function(loc_376_, loc_381_, "i32,i32,i32->i32");
				loc_380_ = loc_381_(loc_380_, bit32_or(loc_378_ + 15, 0), 1, loc_373_)
				if not (rt_not_equal_i32(loc_380_, 1)) then
					loc_380_ = loc_374_;
					loc_374_ = rt_load_i32_from_u8(loc_377_, loc_378_, 15);
				end
			end
			loc_375_[1] = bit32_or(loc_378_ + 16, 0);
			return loc_374_, loc_373_
		end), "i32->i32")
	end)(module_locals[51], module_locals[114], module_locals[112], module_locals[3]);
	module_locals[85] = { nil };
	module_locals[53][1] = (function(loc_382_, loc_383_, loc_384_)
		return rt_function_type((function(loc_385_, loc_386_, loc_387_, loc_388_)
			local loc_389_, loc_390_, loc_391_, loc_392_, loc_393_, loc_394_, loc_395_, loc_396_, loc_397_, loc_398_, loc_399_, loc_400_, loc_401_, loc_402_
			loc_398_ = 0;
			loc_397_ = 0;
			if rt_greater_than_s32(loc_386_, 1) then
				loc_389_ = loc_388_;
				loc_391_ = loc_384_;
				loc_392_ = loc_382_;
				loc_393_ = loc_383_;
				loc_395_ = loc_385_;
				loc_396_ = loc_387_;
				loc_402_ = loc_386_;
				loc_390_ = loc_395_;
				loc_394_ = bit32_or(loc_402_ + -1, 0);
				repeat
					rt_yield_budget = rt_yield_budget - 1
					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
					loc_402_ = buffer_read_i32(loc_391_[1], loc_396_, 4);
					loc_400_ = buffer_read_i32(loc_391_[1], loc_396_, 8);
					if rt_equal_i32(loc_402_, loc_400_) then
						loc_399_ = loc_398_;
						loc_398_ = loc_402_;
						loc_400_ = 0;
					else
						loc_399_ = loc_398_;
						loc_398_ = loc_402_;
						loc_400_ = bit32_or(loc_400_ - loc_398_, 0);
						loc_402_ = loc_389_;
						loc_401_ = loc_393_[1](loc_398_, 10, loc_400_, loc_402_)
						loc_402_ = bit32_or(bit32_or(loc_401_ - loc_398_, 0) + 1, 0);
						if rt_not_equal_i32(loc_401_, 0) then
							loc_394_, loc_400_ = loc_400_, loc_394_;
							loc_400_, loc_399_ = loc_399_, loc_400_;
							loc_399_, loc_397_ = loc_397_, loc_399_;
							loc_397_, loc_402_ = loc_402_, loc_397_;
						else
							loc_394_, loc_400_ = loc_400_, loc_394_;
							loc_400_, loc_399_ = loc_399_, loc_400_;
							loc_399_, loc_397_ = loc_397_, loc_399_;
							loc_397_, loc_402_ = loc_402_, loc_397_;
							loc_397_ = loc_394_;
						end
						if rt_less_than_u32(loc_397_, loc_402_) then
							loc_394_ = loc_402_;
						else
							loc_394_ = loc_402_;
							loc_397_ = loc_402_;
						end
						if not (rt_equal_i32(loc_397_, 0)) then
							rt_memory_copy(loc_391_, loc_395_, loc_391_, loc_398_, loc_397_)
						end
						loc_398_ = buffer_read_i32(loc_391_[1], loc_396_, 4);
						loc_398_ = bit32_or(loc_398_ + loc_397_, 0);
						rt_store_i32(loc_391_, loc_396_, 4, loc_398_)
						loc_395_ = bit32_or(loc_395_ + loc_397_, 0);
						if rt_not_equal_i32(loc_401_, 0) then
							loc_400_ = 2;
							loc_399_ = 0;
							loc_397_ = 2;
						else
							loc_394_ = bit32_or(loc_394_ - loc_397_, 0);
							if rt_equal_i32(loc_394_, 0) then
								loc_400_ = 2;
								loc_399_ = 0;
								loc_397_ = 2;
							else
								loc_397_ = buffer_read_i32(loc_391_[1], loc_396_, 8);
								if rt_equal_i32(loc_398_, loc_397_) then
									loc_397_ = loc_399_;
									loc_399_ = loc_400_;
									loc_400_ = 0;
								else
									loc_397_ = loc_399_;
									loc_399_ = loc_400_;
									rt_store_i32(loc_391_, loc_396_, 4, bit32_or(loc_398_ + 1, 0))
									loc_398_ = rt_load_i32_from_u8(loc_391_, loc_398_, 0);
									loc_400_ = 1;
								end
							end
						end
					end
					if (loc_400_) >= 0 and (loc_400_) < 2 then
						if (loc_400_) < 1 then
							loc_400_ = loc_398_;
							loc_400_ = loc_389_;
							loc_398_ = loc_392_[1](loc_396_, loc_400_)
							if rt_greater_than_s32(loc_398_, -1) then
								loc_400_ = 0;
							else
								loc_400_ = loc_399_;
								loc_399_ = loc_397_;
								loc_400_ = 1;
								loc_399_ = 0;
								loc_397_ = 0;
							end
						else
							loc_400_ = 0;
						end
					else
						loc_400_ = 1;
					end
					if not (rt_not_equal_i32(loc_400_, 0)) then
						rt_store_i32_into_i8(loc_391_, loc_395_, 0, loc_398_)
						loc_395_ = bit32_or(loc_395_ + 1, 0);
						if rt_equal_i32(rt_and_i32(loc_398_, 255), 10) then
							loc_399_ = 0;
							loc_397_ = 2;
						else
							loc_394_ = bit32_or(loc_394_ + -1, 0);
							if rt_not_equal_i32(loc_394_, 0) then
								loc_399_ = 1;
								loc_397_ = 65535;
							else
								loc_399_ = 0;
								loc_397_ = 1;
							end
						end
					end
					loc_398_ = loc_399_;
				until loc_399_ == 0
				if (loc_397_) >= 0 and (loc_397_) < 2 then
					if (loc_397_) < 1 then
						loc_394_ = 0;
						if rt_equal_i32(loc_395_, loc_390_) then
							loc_396_ = 1;
						else
							loc_396_ = rt_load_i32_from_u8(loc_391_, loc_396_, 0);
							if rt_equal_i32(rt_and_i32(loc_396_, 16), 0) then
								loc_396_ = 2;
							else
								loc_396_ = 0;
							end
						end
					else
						loc_396_ = 0;
					end
				else
					loc_396_ = 0;
				end
				if (loc_396_) >= 0 and (loc_396_) < 2 then
					if (loc_396_) < 1 then
						if rt_not_equal_i32(loc_390_, 0) then
							loc_396_ = 0;
						else
							loc_396_ = loc_390_;
							loc_396_ = 2;
							loc_390_ = 0;
						end
					else
						loc_396_ = 1;
					end
				else
					loc_396_ = 1;
				end
			else
				loc_389_ = loc_388_;
				loc_391_ = loc_384_;
				loc_392_ = loc_382_;
				loc_393_ = loc_383_;
				loc_395_ = loc_385_;
				loc_396_ = loc_387_;
				loc_400_ = loc_397_;
				loc_401_ = loc_398_;
				loc_402_ = loc_386_;
				loc_401_ = buffer_read_i32(loc_391_[1], loc_396_, 60);
				rt_store_i32(loc_391_, loc_396_, 60, rt_or_i32(bit32_or(loc_401_ + -1, 0), loc_401_))
				if rt_equal_i32(loc_402_, 1) then
					loc_390_ = loc_395_;
					loc_394_ = loc_402_;
					loc_396_ = 0;
				else
					loc_394_ = loc_402_;
					loc_402_ = loc_395_;
					loc_396_ = 2;
					loc_390_ = 0;
				end
			end
			if (loc_396_) >= 0 and (loc_396_) < 2 then
				if (loc_396_) < 1 then
					loc_390_, loc_394_ = loc_394_, loc_390_;
					rt_store_i32_into_i8(loc_391_, loc_395_, 0, 0)
					loc_395_ = 0;
					loc_390_ = loc_394_;
				else
					loc_395_ = 0;
				end
			else
				loc_395_ = 1;
			end
			if not (rt_not_equal_i32(loc_395_, 0)) then
				loc_390_ = loc_394_;
			end
			return loc_390_, loc_389_
		end), "i32,i32,i32->i32")
	end)(module_locals[52], module_locals[85], module_locals[3]);
	module_locals[54] = { nil };
	module_locals[87] = { nil };
	module_locals[54][1] = (function(loc_403_, loc_404_)
		return rt_function_type((function(loc_405_, loc_406_)
			local loc_407_, loc_408_, loc_409_, loc_410_, loc_411_, loc_412_, loc_413_, loc_414_, loc_415_
			loc_409_ = rt_load_i32_from_u8(loc_404_, loc_405_, 0);
			loc_410_ = loc_404_;
			loc_413_ = (rt_equal_i32(loc_409_, 114) and 1 or 0);
			loc_408_ = 335544320;
			loc_407_ = 67108864;
			loc_414_ = 268435456;
			if rt_not_equal_i32(loc_413_, 0) then
				loc_411_ = loc_403_;
				loc_412_ = loc_405_;
				loc_415_ = loc_406_;
			else
				loc_411_ = loc_403_;
				loc_412_ = loc_405_;
				loc_415_ = loc_406_;
				loc_407_ = loc_414_;
			end
			loc_415_ = loc_411_[1](loc_412_, 43, loc_415_)
			if not (rt_not_equal_i32(loc_415_, 0)) then
				loc_408_ = loc_407_;
			end
			loc_414_ = loc_411_[1](loc_412_, 120, loc_414_)
			loc_412_ = rt_or_i32(loc_408_, 16384);
			if not (rt_not_equal_i32(loc_414_, 0)) then
				loc_412_ = loc_408_;
			end
			loc_408_ = rt_or_i32(loc_412_, 4096);
			if not (rt_not_equal_i32(loc_413_, 0)) then
				loc_412_ = loc_408_;
			end
			loc_408_ = rt_or_i32(loc_412_, 32768);
			if not (rt_equal_i32(loc_409_, 119)) then
				loc_408_ = loc_412_;
			end
			return rt_or_i32(loc_408_, (rt_equal_i32(loc_409_, 97) and 1 or 0)), loc_407_
		end), "i32->i32")
	end)(module_locals[87], module_locals[3]);
	module_locals[55] = { nil };
	module_locals[56] = { nil };
	module_locals[55][1] = (function(loc_416_, loc_417_, loc_418_, loc_419_, loc_420_, loc_421_, loc_422_, loc_423_)
		return rt_function_type((function(loc_424_)
			local loc_425_, loc_426_, loc_427_, loc_428_, loc_429_, loc_430_, loc_431_, loc_432_, loc_433_, loc_434_, loc_435_, loc_436_, loc_437_, loc_438_, loc_439_
			loc_439_ = loc_422_[1];
			loc_426_ = loc_422_;
			loc_434_ = bit32_or(loc_439_ - 16, 0);
			loc_426_[1] = loc_434_;
			loc_439_ = rt_load_i32_from_u8(loc_423_, 0, 70864);
			loc_427_ = loc_423_;
			loc_435_ = 0;
			loc_436_ = 0;
			loc_437_ = 0;
			if rt_not_equal_i32(rt_and_i32(loc_439_, 1), 0) then
				loc_425_ = loc_424_;
				loc_428_ = loc_416_;
				loc_429_ = loc_417_;
				loc_430_ = loc_418_;
				loc_431_ = loc_419_;
				loc_432_ = loc_420_;
				loc_433_ = loc_421_;
				loc_435_ = 0;
			else
				loc_425_ = loc_424_;
				loc_428_ = loc_416_;
				loc_429_ = loc_417_;
				loc_430_ = loc_418_;
				loc_431_ = loc_419_;
				loc_432_ = loc_420_;
				loc_433_ = loc_421_;
				loc_439_ = rt_load_i32_from_u8(loc_427_, 0, 70864);
				if rt_not_equal_i32(rt_and_i32(loc_439_, 1), 0) then
					loc_435_, loc_437_ = loc_437_, loc_435_;
					loc_435_ = 0;
				else
					loc_438_ = loc_436_;
					loc_439_ = loc_425_;
					loc_435_, loc_437_ = loc_437_, loc_435_;
					loc_436_ = loc_428_;
					loc_425_ = loc_437_;
					loc_428_ = loc_438_;
					loc_438_ = 3;
					loc_437_ = loc_439_;
					repeat
						rt_yield_budget = rt_yield_budget - 1
						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
						loc_439_ = loc_435_;
						loc_439_ = loc_437_;
						loc_435_ = loc_429_[1](loc_438_, bit32_or(loc_434_ + 8, 0), loc_439_)
						if rt_equal_i32(loc_435_, 0) then
							loc_439_ = loc_425_;
							loc_425_ = rt_load_i32_from_u8(loc_427_, loc_434_, 8);
							if rt_not_equal_i32(loc_425_, 0) then
								loc_425_ = 0;
							else
								loc_425_ = buffer_read_i32(loc_427_[1], loc_434_, 12);
								loc_435_ = loc_432_[1](bit32_or(loc_425_ + 1, 0), loc_437_)
								if rt_equal_i32(loc_435_, 0) then
									loc_425_ = 1;
									loc_439_ = 0;
									loc_428_ = 2;
								else
									loc_425_ = loc_430_[1](loc_438_, loc_435_, loc_425_, loc_437_)
									if rt_not_equal_i32(loc_425_, 0) then
										loc_425_ = 1;
										loc_439_ = 0;
										loc_428_ = 1;
									else
										loc_425_ = buffer_read_i32(loc_427_[1], loc_434_, 12);
										rt_store_i32_into_i8(loc_427_, bit32_or(loc_435_ + loc_425_, 0), 0, 0)
										loc_425_ = loc_431_[1](loc_438_, loc_435_, loc_437_)
										loc_433_[1](loc_435_, loc_437_)
										if rt_not_equal_i32(loc_425_, 0) then
											loc_425_ = 1;
											loc_439_ = 0;
											loc_428_ = 2;
										else
											loc_425_ = 0;
										end
									end
								end
							end
							if not (rt_not_equal_i32(loc_425_, 0)) then
								loc_439_ = 1;
								loc_428_ = 65535;
								loc_438_ = bit32_or(loc_438_ + 1, 0);
							end
						else
							loc_439_ = loc_425_;
							loc_439_ = 0;
							loc_428_ = 0;
						end
						loc_425_ = loc_439_;
					until loc_439_ == 0
					if (loc_428_) >= 0 and (loc_428_) < 2 then
						if (loc_428_) < 1 then
							if rt_not_equal_i32(loc_435_, 8) then
								loc_425_ = loc_437_;
								loc_428_ = loc_436_;
								loc_437_ = 0;
							else
								loc_425_ = loc_437_;
								loc_428_ = loc_436_;
								rt_store_i32_into_i8(loc_427_, 0, 70864, 1)
								loc_437_ = 1;
							end
						else
							loc_436_, loc_437_ = loc_437_, loc_436_;
							loc_428_ = loc_437_;
							loc_437_ = 0;
							loc_425_ = loc_436_;
						end
					else
						loc_428_ = loc_436_;
						loc_436_[1](70, loc_437_)
						loc_437_ = 2;
						loc_436_ = error('unreachable code');
					end
					if (loc_437_) >= 0 and (loc_437_) < 2 then
						if (loc_437_) < 1 then
							loc_436_ = loc_428_;
							loc_428_ = loc_436_;
							loc_437_ = loc_425_;
							loc_436_[1](71, loc_437_)
							loc_435_ = 1;
							loc_437_ = error('unreachable code');
						else
							loc_435_ = 0;
						end
					else
						loc_435_ = 1;
					end
				end
			end
			if not (rt_not_equal_i32(loc_435_, 0)) then
				loc_426_[1] = bit32_or(loc_434_ + 16, 0);
			end
			return loc_425_
		end), "->")
	end)(module_locals[24], module_locals[31], module_locals[32], module_locals[56], module_locals[106], module_locals[109], module_locals[114], module_locals[3]);
	module_locals[90] = { nil };
	module_locals[56][1] = (function(loc_440_, loc_441_, loc_442_, loc_443_)
		return rt_function_type((function(loc_444_, loc_445_, loc_446_)
			local loc_447_, loc_448_, loc_449_, loc_450_, loc_451_, loc_452_, loc_453_, loc_454_, loc_455_, loc_456_, loc_457_, loc_458_
			loc_454_ = buffer_read_i32(loc_443_[1], 0, 70856);
			loc_449_ = loc_443_;
			loc_458_ = buffer_read_i32(loc_449_[1], 0, 70868);
			loc_455_ = 0;
			if rt_not_equal_i32(loc_454_, loc_458_) then
				loc_447_ = loc_446_;
				loc_448_ = loc_444_;
				loc_450_ = loc_440_;
				loc_451_ = loc_441_;
				loc_452_ = loc_442_;
				loc_453_ = loc_445_;
				loc_456_ = 0;
			else
				loc_447_ = loc_446_;
				loc_448_ = loc_444_;
				loc_450_ = loc_440_;
				loc_451_ = loc_441_;
				loc_452_ = loc_442_;
				loc_453_ = loc_445_;
				loc_458_ = loc_455_;
				loc_455_ = buffer_read_i32(loc_449_[1], 0, 70860);
				loc_456_ = 8;
				loc_458_ = rt_shift_left_i32(loc_454_, 1);
				loc_457_ = 4;
				if rt_not_equal_i32(loc_454_, 0) then
					loc_447_, loc_451_ = loc_451_, loc_447_;
					loc_451_, loc_457_ = loc_457_, loc_451_;
				else
					loc_447_, loc_451_ = loc_451_, loc_447_;
					loc_451_, loc_457_ = loc_457_, loc_451_;
					loc_458_ = loc_451_;
				end
				loc_457_ = loc_452_[1](loc_456_, loc_458_, loc_457_)
				if rt_not_equal_i32(loc_457_, 0) then
					loc_451_ = rt_shift_left_i32(loc_454_, 3);
					if not (rt_equal_i32(loc_451_, 0)) then
						rt_memory_copy(loc_449_, loc_457_, loc_449_, loc_455_, loc_451_)
					end
					loc_451_ = loc_447_;
					rt_store_i32(loc_449_, 0, 70868, loc_458_)
					rt_store_i32(loc_449_, 0, 70860, loc_457_)
					loc_447_[1](loc_455_, loc_456_)
					loc_456_ = 0;
				else
					loc_451_ = loc_457_;
					loc_457_ = loc_448_;
					loc_456_, loc_458_ = loc_458_, loc_456_;
					loc_451_ = loc_447_;
					loc_456_ = 1;
					loc_448_ = -1;
					loc_447_ = loc_458_;
				end
			end
			if not (rt_not_equal_i32(loc_456_, 0)) then
				loc_456_ = loc_447_;
				loc_448_, loc_453_ = loc_453_, loc_448_;
				loc_447_ = loc_448_;
				loc_448_ = loc_454_;
				loc_454_ = loc_455_;
				loc_455_ = loc_456_;
				repeat
					rt_yield_budget = rt_yield_budget - 1
					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
					loc_456_ = loc_454_;
					loc_456_ = rt_load_i32_from_u8(loc_449_, loc_447_, 0);
					loc_456_ = bit32_or(loc_456_ + -46, 0);
					if (loc_456_) >= 0 and (loc_456_) < 2 then
						if (loc_456_) < 1 then
							loc_454_ = loc_447_;
							loc_456_ = loc_447_;
							loc_456_ = rt_load_i32_from_u8(loc_449_, loc_454_, 1);
							loc_447_ = bit32_or(loc_454_ + 1, 0);
							if rt_equal_i32(loc_456_, 0) then
								loc_456_ = 1;
							else
								if rt_not_equal_i32(loc_456_, 47) then
									loc_456_ = 0;
								else
									loc_456_ = loc_447_;
									loc_456_ = 1;
									loc_447_ = bit32_or(loc_454_ + 2, 0);
								end
							end
						else
							loc_454_ = loc_447_;
							loc_456_ = loc_447_;
							loc_456_ = 1;
							loc_447_ = bit32_or(loc_454_ + 1, 0);
						end
					else
						loc_454_ = loc_447_;
						loc_456_ = 0;
					end
				until loc_456_ == 0
				loc_454_ = loc_450_[1](loc_454_, loc_455_)
				if rt_not_equal_i32(loc_454_, 0) then
					rt_store_i32(loc_449_, 0, 70856, bit32_or(loc_448_ + 1, 0))
					loc_455_ = buffer_read_i32(loc_449_[1], 0, 70860);
					loc_455_ = bit32_or(loc_455_ + rt_shift_left_i32(loc_448_, 3), 0);
					rt_store_i32(loc_449_, loc_455_, 4, loc_453_)
					rt_store_i32(loc_449_, loc_455_, 0, loc_454_)
					loc_448_ = 0;
				else
					loc_455_ = loc_453_;
					loc_453_ = loc_454_;
					loc_454_ = loc_448_;
					loc_448_ = -1;
				end
			end
			return loc_448_, loc_447_
		end), "i32,i32->i32")
	end)(module_locals[90], module_locals[109], module_locals[111], module_locals[3]);
	module_locals[57] = { nil };
	module_locals[58] = { nil };
	module_locals[57][1] = (function(loc_459_, loc_460_, loc_461_, loc_462_)
		return rt_function_type((function(loc_463_, loc_464_, loc_465_, loc_466_, loc_467_)
			local loc_468_, loc_469_, loc_470_, loc_471_, loc_472_, loc_473_, loc_474_, loc_475_, loc_476_, loc_477_
			loc_477_ = loc_461_[1];
			loc_470_ = loc_461_;
			loc_472_ = bit32_or(loc_477_ - 16, 0);
			loc_470_[1] = loc_472_;
			rt_store_i32(loc_462_, loc_472_, 12, loc_466_)
			loc_471_ = loc_462_;
			if rt_equal_i32(0, 0) then
				loc_468_ = loc_465_;
				loc_469_ = loc_467_;
				loc_473_ = loc_459_;
				loc_475_ = loc_464_;
				loc_476_ = loc_463_;
				loc_477_ = loc_460_;
				loc_474_ = loc_477_;
				loc_469_ = loc_477_[1](loc_476_, loc_475_, loc_468_, loc_469_)
			else
				loc_468_ = loc_465_;
				loc_469_ = loc_459_;
				loc_474_ = loc_460_;
				loc_475_ = loc_464_;
				loc_476_ = loc_463_;
				loc_477_ = loc_467_;
				loc_473_ = loc_469_;
				loc_469_ = loc_469_[1](loc_476_, loc_475_, loc_468_, bit32_or(loc_472_ + 12, 0), 0, loc_477_)
			end
			loc_470_[1] = bit32_or(loc_472_ + 16, 0);
			return loc_469_, loc_468_
		end), "i32,i32,i32,i32->i32")
	end)(module_locals[21], module_locals[58], module_locals[114], module_locals[3]);
	module_locals[86] = { nil };
	module_locals[58][1] = (function(loc_478_, loc_479_, loc_480_, loc_481_)
		return rt_function_type((function(loc_482_, loc_483_, loc_484_, loc_485_)
			local loc_486_, loc_487_, loc_488_, loc_489_, loc_490_, loc_491_, loc_492_, loc_493_, loc_494_, loc_495_, loc_496_, loc_497_, loc_498_, loc_499_, loc_500_, loc_501_, loc_502_, loc_503_, loc_504_
			loc_489_ = loc_478_;
			loc_490_ = loc_479_;
			loc_491_ = loc_480_;
			loc_488_ = loc_481_;
			loc_504_ = loc_485_;
			loc_478_[1](loc_504_)
			loc_492_ = 0;
			loc_487_ = bit32_or(loc_482_ + -1, 0);
			loc_493_ = loc_483_;
			loc_494_ = loc_484_;
			repeat
				rt_yield_budget = rt_yield_budget - 1
				if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
				loc_487_ = bit32_or(loc_487_ + 1, 0);
				loc_504_ = rt_load_i32_from_u8(loc_488_, loc_487_, 0);
			until not (rt_equal_i32(loc_504_, 47))
			loc_496_ = buffer_read_i32(loc_488_[1], 0, 70856);
			loc_495_ = 0;
			if rt_equal_i32(loc_496_, 0) then
				loc_492_ = 0;
			else
				loc_502_ = loc_494_;
				loc_503_ = loc_495_;
				loc_504_ = loc_496_;
				loc_498_ = buffer_read_i32(loc_488_[1], 0, 70860);
				loc_494_ = loc_487_;
				loc_497_ = loc_493_;
				loc_495_ = loc_502_;
				loc_496_ = loc_503_;
				loc_493_ = loc_504_;
				loc_487_ = -1;
				repeat
					rt_yield_budget = rt_yield_budget - 1
					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
					loc_504_ = bit32_or(loc_498_ + rt_shift_left_i32(loc_493_, 3), 0);
					loc_500_ = buffer_read_i32(loc_488_[1], bit32_or(loc_504_ + -8, 0), 0);
					loc_503_ = loc_486_;
					loc_501_ = loc_491_[1](loc_500_, loc_503_)
					if rt_equal_i32(loc_487_, -1) then
						loc_499_ = loc_493_;
						loc_493_ = loc_504_;
						loc_504_ = 0;
					else
						loc_499_ = loc_493_;
						loc_493_ = loc_504_;
						if rt_less_than_equal_u32(loc_501_, loc_496_) then
							loc_504_ = 1;
						else
							loc_504_ = 0;
						end
					end
					if not (rt_not_equal_i32(loc_504_, 0)) then
						loc_502_ = rt_load_i32_from_u8(loc_488_, loc_494_, 0);
						if rt_not_equal_i32(loc_501_, 0) then
							loc_493_, loc_501_ = loc_501_, loc_493_;
							loc_504_ = 0;
						else
							loc_493_, loc_501_ = loc_501_, loc_493_;
							if rt_not_equal_i32(rt_and_i32(loc_502_, 255), 47) then
								loc_504_ = 1;
							else
								loc_504_ = 0;
							end
						end
						if rt_not_equal_i32(loc_504_, 0) then
							loc_502_ = 0;
						else
							loc_504_ = loc_486_;
							loc_504_ = loc_490_[1](loc_494_, loc_500_, loc_493_, loc_504_)
							if rt_not_equal_i32(loc_504_, 0) then
								loc_502_ = 1;
							else
								if not (rt_equal_i32(loc_493_, 0)) then
									loc_503_ = loc_493_;
									loc_504_ = loc_500_;
									loc_500_ = loc_504_;
									loc_493_ = loc_503_;
									loc_502_ = loc_503_;
									loc_503_ = bit32_or(loc_504_ + -1, 0);
									repeat
										rt_yield_budget = rt_yield_budget - 1
										if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
										loc_504_ = loc_492_;
										loc_504_ = rt_load_i32_from_u8(loc_488_, bit32_or(loc_503_ + loc_502_, 0), 0);
										if rt_not_equal_i32(loc_504_, 47) then
											loc_504_ = 0;
											loc_492_ = 1;
										else
											loc_502_ = bit32_or(loc_502_ + -1, 0);
											if rt_not_equal_i32(loc_502_, 0) then
												loc_504_ = 1;
												loc_492_ = 65535;
											else
												loc_504_ = 0;
												loc_492_ = 0;
											end
										end
									until loc_504_ == 0
									if not (rt_not_equal_i32(loc_492_, 0)) then
										loc_502_ = 0;
									end
									loc_502_ = rt_load_i32_from_u8(loc_488_, bit32_or(loc_494_ + loc_502_, 0), 0);
								end
								loc_502_ = rt_and_i32(loc_502_, 255);
								if rt_equal_i32(loc_502_, 47) then
									loc_502_ = 0;
								else
									if rt_not_equal_i32(loc_502_, 0) then
										loc_502_ = 1;
									else
										loc_502_ = 0;
									end
								end
							end
						end
						if not (rt_not_equal_i32(loc_502_, 0)) then
							rt_store_i32(loc_488_, loc_497_, 0, loc_500_)
							loc_487_ = buffer_read_i32(loc_488_[1], bit32_or(loc_501_ + -4, 0), 0);
							loc_496_ = loc_493_;
						end
					end
					loc_499_ = bit32_or(loc_499_ + -1, 0);
					loc_493_ = loc_499_;
				until loc_499_ == 0
				if rt_not_equal_i32(loc_487_, -1) then
					loc_496_ = bit32_or(bit32_or(loc_494_ + loc_496_, 0) + -1, 0);
					repeat
						rt_yield_budget = rt_yield_budget - 1
						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
						loc_494_ = loc_493_;
						loc_496_ = bit32_or(loc_496_ + 1, 0);
						loc_494_ = rt_load_i32_from_u8(loc_488_, loc_496_, 0);
						loc_493_ = loc_494_;
					until not (rt_equal_i32(loc_494_, 47))
					loc_494_ = 1106;
					if not (rt_not_equal_i32(loc_493_, 0)) then
						loc_496_ = loc_494_;
					end
					rt_store_i32(loc_488_, loc_495_, 0, loc_496_)
					loc_492_ = 1;
				else
					loc_492_ = loc_487_;
					loc_495_, loc_496_ = loc_496_, loc_495_;
					loc_492_ = 0;
					loc_487_ = loc_494_;
				end
			end
			if not (rt_not_equal_i32(loc_492_, 0)) then
				rt_store_i32(loc_488_, 0, 70852, 44)
				loc_487_ = -1;
			end
			return loc_487_, loc_486_
		end), "i32,i32,i32->i32")
	end)(module_locals[55], module_locals[86], module_locals[91], module_locals[3]);
	module_locals[59] = { nil };
	module_locals[59][1] = (function(loc_505_, loc_506_, loc_507_, loc_508_)
		return rt_function_type((function(loc_509_, loc_510_, loc_511_, loc_512_)
			local loc_513_, loc_514_, loc_515_, loc_516_, loc_517_, loc_518_, loc_519_, loc_520_, loc_521_, loc_522_, loc_523_, loc_524_
			loc_524_ = loc_507_[1];
			loc_515_ = loc_507_;
			loc_517_ = bit32_or(loc_524_ - 32, 0);
			loc_515_[1] = loc_517_;
			loc_514_ = rt_shift_right_u32(bit32_or(rt_and_i32(loc_511_, 503316480) + -33554432, 0), 25);
			if rt_greater_than_u32(loc_514_, 9) then
				loc_513_ = loc_512_;
				loc_516_ = loc_508_;
				loc_518_ = loc_505_;
				loc_519_ = loc_506_;
				loc_520_ = loc_509_;
				loc_521_ = loc_510_;
				loc_522_ = loc_511_;
				loc_520_ = 0;
			else
				loc_513_ = loc_512_;
				loc_516_ = loc_508_;
				loc_518_ = loc_505_;
				loc_519_ = loc_506_;
				loc_520_ = loc_509_;
				loc_521_ = loc_510_;
				loc_522_ = loc_511_;
				loc_514_ = rt_shift_left_i32(1, loc_514_);
				if rt_not_equal_i32(rt_and_i32(loc_514_, 642), 0) then
					loc_520_, loc_522_ = loc_522_, loc_520_;
					loc_524_ = into_bits_i64(4290772670, 4294967295);
					loc_523_ = into_bits_i64(4290756284, 4294967295);
					if not (rt_not_equal_i32(rt_and_i32(loc_520_, 67108864), 0)) then
						loc_524_ = loc_523_;
					end
					loc_523_ = rt_or_i64(loc_524_, into_bits_i64(4194625, 0));
					if not (rt_not_equal_i32(rt_and_i32(loc_520_, 268435456), 0)) then
						loc_523_ = loc_524_;
					end
					loc_524_ = 0;
				else
					loc_520_, loc_522_ = loc_522_, loc_520_;
					loc_523_ = into_bits_i64(4290756284, 4294967295);
					if rt_not_equal_i32(rt_and_i32(loc_514_, 9), 0) then
						loc_524_ = 0;
					else
						loc_524_ = 1;
					end
				end
				if rt_not_equal_i32(loc_524_, 0) then
					loc_520_ = 0;
				else
					loc_514_ = loc_513_;
					loc_513_ = loc_518_[1](loc_522_, bit32_or(loc_517_ + 8, 0), loc_514_)
					if rt_equal_i32(loc_513_, 0) then
						loc_513_, loc_522_ = loc_522_, loc_513_;
						loc_514_, loc_521_ = loc_521_, loc_514_;
						loc_521_, loc_523_ = loc_523_, loc_521_;
						loc_522_ = rt_load_i64(loc_516_, loc_517_, 24);
						loc_523_ = loc_519_[1](loc_513_, rt_and_i32(rt_shift_right_u32(rt_exclusive_or_i32(loc_520_, -1), 24), 1), loc_514_, rt_and_i32(rt_shift_right_u32(loc_520_, 12), 4095), rt_and_i64(loc_522_, loc_521_), loc_522_, rt_and_i32(loc_520_, 4095), bit32_or(loc_517_ + 4, 0), loc_523_)
						loc_522_ = -1;
						if rt_equal_i32(loc_523_, 0) then
							loc_514_ = buffer_read_i32(loc_516_[1], loc_517_, 4);
							loc_520_ = 1;
						else
							rt_store_i32(loc_516_, 0, 70852, loc_523_)
							loc_520_ = 1;
							loc_514_ = loc_522_;
						end
					else
						loc_513_, loc_523_ = loc_523_, loc_513_;
						loc_523_, loc_514_ = loc_514_, loc_523_;
						loc_514_, loc_520_ = loc_520_, loc_514_;
						loc_520_, loc_521_ = loc_521_, loc_520_;
						loc_521_, loc_522_ = loc_522_, loc_521_;
						rt_store_i32(loc_516_, 0, 70852, loc_522_)
						loc_520_ = 1;
						loc_514_ = -1;
						loc_513_ = loc_523_;
					end
				end
			end
			if not (rt_not_equal_i32(loc_520_, 0)) then
				rt_store_i32(loc_516_, 0, 70852, 28)
				loc_514_ = -1;
			end
			loc_515_[1] = bit32_or(loc_517_ + 32, 0);
			return loc_514_, loc_513_
		end), "i32,i32,i32->i32")
	end)(module_locals[29], module_locals[36], module_locals[114], module_locals[3]);
	module_locals[60] = { nil };
	module_locals[60][1] = (function(loc_525_, loc_526_, loc_527_)
		return rt_function_type((function(loc_528_, loc_529_)
			local loc_530_, loc_531_, loc_532_, loc_533_, loc_534_
			loc_532_ = loc_527_;
			loc_534_ = loc_529_;
			loc_526_[1](loc_534_)
			loc_531_ = loc_525_[1](loc_528_, loc_534_)
			if rt_not_equal_i32(loc_531_, 0) then
				loc_533_ = loc_525_;
				loc_534_ = loc_526_;
				rt_store_i32(loc_532_, 0, 70852, loc_531_)
				loc_531_ = -1;
			else
				loc_533_ = loc_525_;
				loc_534_ = loc_526_;
				loc_531_ = 0;
			end
			return loc_531_, loc_530_
		end), "i32->i32")
	end)(module_locals[28], module_locals[55], module_locals[3]);
	module_locals[61] = { nil };
	module_locals[61][1] = (function(loc_535_, loc_536_, loc_537_, loc_538_, loc_539_)
		return rt_function_type((function(loc_540_, loc_541_, loc_542_)
			local loc_543_, loc_544_, loc_545_, loc_546_, loc_547_, loc_548_, loc_549_, loc_550_, loc_551_, loc_552_, loc_553_
			loc_553_ = loc_538_[1];
			loc_545_ = loc_538_;
			loc_547_ = bit32_or(loc_553_ - 16, 0);
			loc_545_[1] = loc_547_;
			if rt_equal_i32(0, 0) then
				loc_543_ = loc_536_;
				loc_544_ = loc_540_;
				loc_546_ = loc_539_;
				loc_548_ = loc_535_;
				loc_551_ = loc_541_;
				loc_552_ = loc_542_;
				loc_553_ = loc_537_;
				loc_549_ = loc_543_;
				loc_550_ = buffer_read_i32(loc_546_[1], 0, 70876);
				loc_552_ = loc_543_[1](loc_544_, bit32_or(loc_547_ + 12, 0), 70872, loc_550_, loc_552_)
			else
				loc_543_ = loc_536_;
				loc_544_ = loc_540_;
				loc_546_ = loc_539_;
				loc_550_ = loc_535_;
				loc_551_ = loc_541_;
				loc_552_ = loc_542_;
				loc_553_ = loc_537_;
				loc_548_ = loc_550_;
				loc_549_ = loc_543_;
				loc_552_ = loc_550_[1](loc_544_, bit32_or(loc_547_ + 12, 0), 70872, 70876, 1, loc_552_)
			end
			loc_550_ = -1;
			if rt_not_equal_i32(loc_552_, -1) then
				loc_550_ = loc_553_;
				loc_543_ = buffer_read_i32(loc_546_[1], 0, 70872);
				loc_544_ = loc_553_[1](loc_552_, loc_543_, loc_551_, loc_544_)
			else
				loc_544_, loc_551_ = loc_551_, loc_544_;
				loc_551_, loc_553_ = loc_553_, loc_551_;
				loc_550_, loc_552_ = loc_552_, loc_550_;
				loc_550_ = loc_551_;
				rt_store_i32(loc_546_, 0, 70852, 44)
				loc_544_ = loc_552_;
				loc_543_ = loc_553_;
			end
			loc_545_[1] = bit32_or(loc_547_ + 16, 0);
			return loc_544_, loc_543_
		end), "i32,i32->i32")
	end)(module_locals[21], module_locals[57], module_locals[59], module_locals[114], module_locals[3]);
	module_locals[62] = { nil };
	module_locals[62][1] = (function(loc_554_, loc_555_, loc_556_, loc_557_)
		return rt_function_type((function(loc_558_, loc_559_, loc_560_, loc_561_)
			local loc_562_, loc_563_, loc_564_, loc_565_, loc_566_, loc_567_, loc_568_, loc_569_, loc_570_
			loc_570_ = loc_556_[1];
			loc_564_ = loc_556_;
			loc_566_ = bit32_or(loc_570_ - 32, 0);
			loc_564_[1] = loc_566_;
			loc_570_ = bit32_or(loc_559_ + -1, 0);
			if (loc_570_) >= 0 and (loc_570_) < 4 then
				if (loc_570_) < 2 then
					if (loc_570_) < 1 then
						loc_562_ = loc_561_;
						loc_563_ = loc_559_;
						loc_565_ = loc_557_;
						loc_567_ = loc_554_;
						loc_568_ = loc_555_;
						loc_569_ = loc_560_;
						loc_570_ = loc_558_;
						loc_569_ = 1;
					else
						loc_562_ = loc_561_;
						loc_563_ = loc_560_;
						loc_565_ = loc_557_;
						loc_567_ = loc_554_;
						loc_568_ = loc_555_;
						loc_569_ = loc_559_;
						loc_570_ = loc_558_;
						loc_569_ = 1;
						loc_563_ = 0;
					end
				elseif (loc_570_) > 2 then
					loc_562_ = loc_561_;
					loc_563_ = loc_559_;
					loc_565_ = loc_557_;
					loc_567_ = loc_554_;
					loc_568_ = loc_555_;
					loc_569_ = loc_558_;
					loc_570_ = loc_560_;
					rt_store_i32(loc_565_, loc_566_, 8, bit32_or(loc_570_ + 4, 0))
					loc_563_ = buffer_read_i32(loc_565_[1], loc_570_, 0);
					loc_570_ = loc_562_;
					loc_563_ = loc_568_[1](loc_569_, rt_and_i32(loc_563_, 4095), loc_570_)
					if rt_not_equal_i32(loc_563_, 0) then
						rt_store_i32(loc_565_, 0, 70852, loc_563_)
						loc_569_ = 0;
					else
						loc_570_ = loc_563_;
						loc_569_ = 1;
						loc_563_ = 0;
					end
				else
					loc_562_ = loc_561_;
					loc_563_ = loc_560_;
					loc_565_ = loc_557_;
					loc_567_ = loc_554_;
					loc_568_ = loc_555_;
					loc_569_ = loc_558_;
					loc_570_ = loc_559_;
					loc_570_ = loc_562_;
					loc_570_ = loc_567_[1](loc_569_, bit32_or(loc_566_ + 8, 0), loc_570_)
					if rt_equal_i32(loc_570_, 0) then
						loc_563_ = rt_load_i64(loc_565_, loc_566_, 16);
						loc_570_ = rt_load_i32_from_u16(loc_565_, loc_566_, 10);
						loc_569_ = rt_and_i64(loc_563_, into_bits_i64(64, 0));
						if rt_equal_i64(rt_and_i64(loc_563_, into_bits_i64(16386, 0)), into_bits_i64(0, 0)) then
							if rt_equal_i64(loc_569_, into_bits_i64(0, 0)) then
								loc_569_ = 1;
								loc_563_ = rt_or_i32(loc_570_, 134217728);
							else
								loc_569_ = 1;
								loc_563_ = rt_or_i32(loc_570_, 268435456);
							end
						else
							if rt_equal_i64(loc_569_, into_bits_i64(0, 0)) then
								loc_569_ = 1;
								loc_563_ = rt_or_i32(loc_570_, 67108864);
							else
								loc_569_ = 1;
								loc_563_ = rt_or_i32(loc_570_, 335544320);
							end
						end
					else
						rt_store_i32(loc_565_, 0, 70852, loc_570_)
						loc_569_ = 0;
						loc_563_ = loc_570_;
					end
				end
			else
				loc_562_ = loc_561_;
				loc_563_ = loc_559_;
				loc_565_ = loc_557_;
				loc_567_ = loc_554_;
				loc_568_ = loc_555_;
				loc_569_ = loc_558_;
				loc_570_ = loc_560_;
				rt_store_i32(loc_565_, 0, 70852, 28)
				loc_569_ = 0;
			end
			if not (rt_not_equal_i32(loc_569_, 0)) then
				loc_563_ = -1;
			end
			loc_564_[1] = bit32_or(loc_566_ + 32, 0);
			return loc_563_, loc_562_
		end), "i32,i32,i32->i32")
	end)(module_locals[29], module_locals[30], module_locals[114], module_locals[3]);
	module_locals[63] = { nil };
	module_locals[63][1] = (function(loc_571_, loc_572_, loc_573_)
		return rt_function_type((function(loc_574_, loc_575_)
			local loc_576_, loc_577_, loc_578_, loc_579_, loc_580_, loc_581_, loc_582_, loc_583_
			loc_583_ = loc_572_[1];
			loc_578_ = loc_572_;
			loc_580_ = bit32_or(loc_583_ - 32, 0);
			loc_578_[1] = loc_580_;
			loc_579_ = loc_573_;
			loc_583_ = loc_575_;
			loc_582_ = loc_571_[1](loc_574_, bit32_or(loc_580_ + 8, 0), loc_583_)
			loc_577_ = 0;
			if rt_not_equal_i32(loc_582_, 0) then
				loc_581_ = loc_571_;
				loc_583_ = 0;
			else
				loc_581_ = loc_571_;
				loc_583_ = loc_582_;
				loc_583_ = rt_load_i32_from_u8(loc_579_, loc_580_, 8);
				loc_582_ = 59;
				if rt_not_equal_i32(loc_583_, 2) then
					loc_583_ = 0;
				else
					loc_583_ = rt_load_i32_from_u8(loc_579_, loc_580_, 16);
					if rt_not_equal_i32(rt_and_i32(loc_583_, 36), 0) then
						loc_583_ = 0;
					else
						loc_583_ = loc_577_;
						loc_583_ = 1;
						loc_577_ = 1;
					end
				end
			end
			if not (rt_not_equal_i32(loc_583_, 0)) then
				rt_store_i32(loc_579_, 0, 70852, loc_582_)
				loc_577_ = 0;
			end
			loc_578_[1] = bit32_or(loc_580_ + 32, 0);
			return loc_577_, loc_576_
		end), "i32->i32")
	end)(module_locals[29], module_locals[114], module_locals[3]);
	module_locals[64] = { nil };
	module_locals[64][1] = (function(loc_584_, loc_585_, loc_586_)
		return rt_function_type((function(loc_587_, loc_588_, loc_589_, loc_590_)
			local loc_591_, loc_592_, loc_593_, loc_594_, loc_595_, loc_596_, loc_597_, loc_598_
			loc_598_ = loc_585_[1];
			loc_593_ = loc_585_;
			loc_595_ = bit32_or(loc_598_ - 16, 0);
			loc_593_[1] = loc_595_;
			loc_594_ = loc_586_;
			loc_598_ = loc_590_;
			loc_592_ = loc_584_[1](loc_587_, loc_588_, rt_and_i32(loc_589_, 255), bit32_or(loc_595_ + 8, 0), loc_598_)
			if rt_equal_i32(loc_592_, 0) then
				loc_596_ = loc_584_;
				loc_592_ = rt_load_i64(loc_594_, loc_595_, 8);
			else
				loc_596_ = loc_584_;
				loc_598_ = loc_592_;
				loc_597_ = 0;
				loc_592_ = 70;
				if not (rt_equal_i32(loc_598_, 76)) then
					loc_592_ = loc_598_;
				end
				rt_store_i32(loc_594_, loc_597_, 70852, loc_592_)
				loc_592_ = into_bits_i64(4294967295, 4294967295);
			end
			loc_593_[1] = bit32_or(loc_595_ + 16, 0);
			return loc_592_, loc_591_
		end), "i32,i64,i32->i64")
	end)(module_locals[34], module_locals[114], module_locals[3]);
	module_locals[65] = { nil };
	module_locals[65][1] = (function(loc_599_, loc_600_)
		return rt_function_type((function(loc_601_, loc_602_, loc_603_, loc_604_)
			local loc_605_, loc_606_, loc_607_
			loc_605_ = buffer_read_i32(loc_600_[1], loc_601_, 56);
			loc_607_ = loc_600_;
			loc_606_ = loc_604_;
			loc_606_ = loc_599_[1](loc_605_, loc_602_, loc_603_, loc_606_)
			return loc_606_, loc_605_
		end), "i32,i64,i32->i64")
	end)(module_locals[64], module_locals[3]);
	module_locals[66] = { nil };
	module_locals[66][1] = (function(loc_608_, loc_609_, loc_610_)
		return rt_function_type((function(loc_611_, loc_612_, loc_613_, loc_614_)
			local loc_615_, loc_616_, loc_617_, loc_618_, loc_619_, loc_620_, loc_621_, loc_622_, loc_623_
			loc_623_ = loc_609_[1];
			loc_617_ = loc_609_;
			loc_619_ = bit32_or(loc_623_ - 16, 0);
			loc_617_[1] = loc_619_;
			loc_623_ = -1;
			if rt_greater_than_s32(loc_613_, -1) then
				loc_615_ = loc_613_;
				loc_616_ = loc_614_;
				loc_618_ = loc_610_;
				loc_620_ = loc_608_;
				loc_621_ = loc_612_;
				loc_622_ = loc_611_;
				rt_store_i32(loc_618_, loc_619_, 12, 0)
				loc_616_ = loc_620_[1](loc_622_, loc_621_, loc_615_, bit32_or(loc_619_ + 12, 0), loc_616_)
				if rt_equal_i32(loc_616_, 0) then
					loc_616_ = buffer_read_i32(loc_618_[1], loc_619_, 12);
				else
					rt_store_i32(loc_618_, 0, 70852, loc_616_)
					loc_616_ = -1;
				end
			else
				loc_615_ = loc_613_;
				loc_616_ = loc_612_;
				loc_618_ = loc_610_;
				loc_620_ = loc_608_;
				loc_621_ = loc_611_;
				loc_622_ = loc_623_;
				loc_623_ = loc_614_;
				rt_store_i32(loc_618_, 0, 70852, 28)
				loc_616_ = loc_622_;
				loc_615_ = loc_623_;
			end
			loc_617_[1] = bit32_or(loc_619_ + 16, 0);
			return loc_616_, loc_615_
		end), "i32,i32,i32->i32")
	end)(module_locals[35], module_locals[114], module_locals[3]);
	module_locals[67] = { nil };
	module_locals[67][1] = (function(loc_624_, loc_625_, loc_626_)
		return rt_function_type((function(loc_627_, loc_628_, loc_629_, loc_630_)
			local loc_631_, loc_632_, loc_633_, loc_634_, loc_635_, loc_636_, loc_637_, loc_638_, loc_639_, loc_640_, loc_641_, loc_642_, loc_643_, loc_644_, loc_645_, loc_646_, loc_647_, loc_648_
			loc_648_ = loc_625_[1];
			loc_633_ = loc_625_;
			loc_635_ = bit32_or(loc_648_ - 16, 0);
			rt_store_i32(loc_626_, loc_635_, 12, loc_629_)
			loc_634_ = loc_626_;
			rt_store_i32(loc_634_, loc_635_, 8, loc_628_)
			loc_647_ = buffer_read_i32(loc_634_[1], loc_627_, 24);
			rt_store_i32(loc_634_, loc_635_, 0, loc_647_)
			loc_648_ = buffer_read_i32(loc_634_[1], loc_627_, 20);
			loc_648_ = bit32_or(loc_648_ - loc_647_, 0);
			rt_store_i32(loc_634_, loc_635_, 4, loc_648_)
			loc_646_ = buffer_read_i32(loc_634_[1], loc_627_, 56);
			loc_633_[1] = loc_635_;
			loc_647_ = loc_630_;
			loc_632_ = loc_624_[1](loc_646_, loc_635_, 2, loc_647_)
			loc_639_ = 0;
			loc_640_ = 2;
			loc_641_ = bit32_or(loc_648_ + loc_629_, 0);
			if rt_equal_i32(loc_632_, loc_641_) then
				loc_636_ = loc_624_;
				loc_637_ = loc_627_;
				loc_638_ = loc_629_;
				loc_639_ = 0;
			else
				loc_636_ = loc_624_;
				loc_637_ = loc_627_;
				loc_638_ = loc_629_;
				loc_647_ = loc_635_;
				loc_648_ = loc_641_;
				loc_635_ = loc_647_;
				loc_641_ = loc_647_;
				loc_642_ = loc_648_;
				repeat
					rt_yield_budget = rt_yield_budget - 1
					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
					loc_648_ = loc_639_;
					if rt_greater_than_s32(loc_632_, -1) then
						loc_639_ = loc_631_;
						loc_631_ = loc_640_;
						loc_643_ = loc_642_;
						loc_646_ = loc_641_;
						loc_647_ = loc_632_;
						loc_645_ = buffer_read_i32(loc_634_[1], loc_646_, 4);
						loc_640_ = (rt_greater_than_u32(loc_647_, loc_645_) and 1 or 0);
						loc_648_ = 8;
						loc_644_ = 0;
						if rt_not_equal_i32(loc_640_, 0) then
							loc_632_ = loc_646_;
						else
							loc_632_ = loc_646_;
							loc_648_ = loc_644_;
						end
						loc_644_ = bit32_or(loc_646_ + loc_648_, 0);
						loc_646_ = buffer_read_i32(loc_634_[1], loc_644_, 0);
						loc_648_ = 0;
						if rt_not_equal_i32(loc_640_, 0) then
							loc_641_ = loc_644_;
							loc_642_ = loc_647_;
						else
							loc_641_ = loc_644_;
							loc_642_ = loc_647_;
							loc_645_ = loc_648_;
						end
						loc_645_ = bit32_or(loc_647_ - loc_645_, 0);
						rt_store_i32(loc_634_, loc_644_, 0, bit32_or(loc_646_ + loc_645_, 0))
						loc_644_ = 12;
						loc_646_ = 4;
						if not (rt_not_equal_i32(loc_640_, 0)) then
							loc_644_ = loc_646_;
						end
						loc_644_ = bit32_or(loc_632_ + loc_644_, 0);
						loc_632_ = buffer_read_i32(loc_634_[1], loc_644_, 0);
						rt_store_i32(loc_634_, loc_644_, 0, bit32_or(loc_632_ - loc_645_, 0))
						loc_632_ = buffer_read_i32(loc_634_[1], loc_637_, 56);
						loc_640_ = bit32_or(loc_631_ - loc_640_, 0);
						loc_632_ = loc_636_[1](loc_632_, loc_641_, loc_640_, loc_639_)
						loc_642_ = bit32_or(loc_643_ - loc_642_, 0);
						if rt_not_equal_i32(loc_642_, loc_632_) then
							loc_643_ = 1;
							loc_639_ = 65535;
						else
							loc_643_ = 0;
							loc_639_ = 1;
						end
					else
						loc_645_ = loc_632_;
						loc_646_ = loc_641_;
						loc_647_ = loc_642_;
						loc_648_ = loc_631_;
						loc_631_ = loc_640_;
						loc_643_ = 0;
						loc_639_ = 0;
						loc_632_ = loc_645_;
						loc_641_ = loc_646_;
						loc_640_ = loc_631_;
						loc_642_ = loc_647_;
						loc_631_ = loc_648_;
					end
				until loc_643_ == 0
				if rt_not_equal_i32(loc_639_, 0) then
					loc_639_ = 0;
				else
					loc_639_ = loc_632_;
					rt_store_i32(loc_634_, loc_637_, 24, 0)
					rt_store_i64(loc_634_, loc_637_, 16, into_bits_i64(0, 0))
					loc_639_ = buffer_read_i32(loc_634_[1], loc_637_, 0);
					rt_store_i32(loc_634_, loc_637_, 0, rt_or_i32(loc_639_, 32))
					loc_632_ = 0;
					if rt_equal_i32(loc_640_, 2) then
						loc_639_ = 1;
					else
						loc_640_ = loc_632_;
						loc_641_ = buffer_read_i32(loc_634_[1], loc_641_, 4);
						loc_639_ = 1;
						loc_632_ = bit32_or(loc_638_ - loc_641_, 0);
					end
				end
			end
			if not (rt_not_equal_i32(loc_639_, 0)) then
				loc_639_ = loc_632_;
				loc_639_ = buffer_read_i32(loc_634_[1], loc_637_, 40);
				rt_store_i32(loc_634_, loc_637_, 24, loc_639_)
				rt_store_i32(loc_634_, loc_637_, 20, loc_639_)
				loc_632_ = buffer_read_i32(loc_634_[1], loc_637_, 44);
				rt_store_i32(loc_634_, loc_637_, 16, bit32_or(loc_639_ + loc_632_, 0))
				loc_632_ = loc_638_;
			end
			loc_633_[1] = bit32_or(loc_635_ + 16, 0);
			return loc_632_, loc_631_
		end), "i32,i32,i32->i32")
	end)(module_locals[66], module_locals[114], module_locals[3]);
	module_locals[68] = { nil };
	module_locals[68][1] = (function(loc_649_, loc_650_, loc_651_)
		return rt_function_type((function(loc_652_, loc_653_, loc_654_, loc_655_)
			local loc_656_, loc_657_, loc_658_, loc_659_, loc_660_, loc_661_, loc_662_, loc_663_, loc_664_
			loc_664_ = loc_650_[1];
			loc_658_ = loc_650_;
			loc_660_ = bit32_or(loc_664_ - 16, 0);
			loc_658_[1] = loc_660_;
			loc_664_ = -1;
			if rt_greater_than_s32(loc_654_, -1) then
				loc_656_ = loc_654_;
				loc_657_ = loc_655_;
				loc_659_ = loc_651_;
				loc_661_ = loc_649_;
				loc_662_ = loc_653_;
				loc_663_ = loc_652_;
				loc_657_ = loc_661_[1](loc_663_, loc_662_, loc_656_, bit32_or(loc_660_ + 12, 0), loc_657_)
				if rt_equal_i32(loc_657_, 0) then
					loc_657_ = buffer_read_i32(loc_659_[1], loc_660_, 12);
				else
					rt_store_i32(loc_659_, 0, 70852, loc_657_)
					loc_657_ = -1;
				end
			else
				loc_656_ = loc_654_;
				loc_657_ = loc_653_;
				loc_659_ = loc_651_;
				loc_661_ = loc_649_;
				loc_662_ = loc_652_;
				loc_663_ = loc_664_;
				loc_664_ = loc_655_;
				rt_store_i32(loc_659_, 0, 70852, 28)
				loc_657_ = loc_663_;
				loc_656_ = loc_664_;
			end
			loc_658_[1] = bit32_or(loc_660_ + 16, 0);
			return loc_657_, loc_656_
		end), "i32,i32,i32->i32")
	end)(module_locals[33], module_locals[114], module_locals[3]);
	module_locals[69] = { nil };
	module_locals[69][1] = (function(loc_665_, loc_666_, loc_667_)
		return rt_function_type((function(loc_668_, loc_669_, loc_670_, loc_671_)
			local loc_672_, loc_673_, loc_674_, loc_675_, loc_676_, loc_677_, loc_678_, loc_679_
			loc_679_ = loc_666_[1];
			loc_674_ = loc_666_;
			loc_676_ = bit32_or(loc_679_ - 16, 0);
			loc_674_[1] = loc_676_;
			rt_store_i32(loc_667_, loc_676_, 12, loc_670_)
			loc_675_ = loc_667_;
			rt_store_i32(loc_675_, loc_676_, 8, loc_669_)
			loc_679_ = loc_671_;
			loc_673_ = loc_665_[1](loc_668_, bit32_or(loc_676_ + 8, 0), 1, bit32_or(loc_676_ + 4, 0), loc_679_)
			if rt_equal_i32(loc_673_, 0) then
				loc_677_ = loc_665_;
				loc_673_ = buffer_read_i32(loc_675_[1], loc_676_, 4);
			else
				loc_677_ = loc_665_;
				loc_679_ = loc_673_;
				loc_678_ = 0;
				loc_673_ = 8;
				if not (rt_equal_i32(loc_679_, 76)) then
					loc_673_ = loc_679_;
				end
				rt_store_i32(loc_675_, loc_678_, 70852, loc_673_)
				loc_673_ = -1;
			end
			loc_674_[1] = bit32_or(loc_676_ + 16, 0);
			return loc_673_, loc_672_
		end), "i32,i32,i32->i32")
	end)(module_locals[33], module_locals[114], module_locals[3]);
	module_locals[70] = { nil };
	module_locals[70][1] = (function(loc_680_, loc_681_, loc_682_, loc_683_)
		return rt_function_type((function(loc_684_, loc_685_, loc_686_, loc_687_)
			local loc_688_, loc_689_, loc_690_, loc_691_, loc_692_, loc_693_, loc_694_, loc_695_, loc_696_, loc_697_, loc_698_, loc_699_, loc_700_
			loc_700_ = loc_682_[1];
			loc_690_ = loc_682_;
			loc_692_ = bit32_or(loc_700_ - 16, 0);
			loc_690_[1] = loc_692_;
			rt_store_i32(loc_683_, loc_692_, 0, loc_685_)
			loc_691_ = loc_683_;
			loc_688_ = buffer_read_i32(loc_691_[1], loc_684_, 44);
			rt_store_i32(loc_691_, loc_692_, 12, loc_688_)
			loc_697_ = buffer_read_i32(loc_691_[1], loc_684_, 40);
			rt_store_i32(loc_691_, loc_692_, 8, loc_697_)
			loc_700_ = bit32_or(loc_686_ - (rt_not_equal_i32(loc_688_, 0) and 1 or 0), 0);
			rt_store_i32(loc_691_, loc_692_, 4, loc_700_)
			loc_698_ = buffer_read_i32(loc_691_[1], loc_684_, 56);
			if rt_equal_i32(loc_700_, 0) then
				loc_689_ = loc_686_;
				loc_693_ = loc_680_;
				loc_695_ = loc_684_;
				loc_696_ = loc_685_;
				loc_699_ = loc_687_;
				loc_700_ = loc_681_;
				loc_694_ = loc_700_;
				loc_699_ = loc_700_[1](loc_698_, loc_697_, loc_688_, loc_699_)
			else
				loc_689_ = loc_686_;
				loc_693_ = loc_697_;
				loc_694_ = loc_688_;
				loc_695_ = loc_684_;
				loc_696_ = loc_685_;
				loc_697_ = loc_681_;
				loc_699_ = loc_680_;
				loc_700_ = loc_687_;
				loc_693_ = loc_699_;
				loc_694_ = loc_697_;
				loc_699_ = loc_699_[1](loc_698_, loc_692_, 2, loc_700_)
			end
			loc_698_ = 0;
			if rt_greater_than_s32(loc_699_, 0) then
				loc_698_ = buffer_read_i32(loc_691_[1], loc_692_, 4);
				if rt_greater_than_u32(loc_699_, loc_698_) then
					loc_697_ = buffer_read_i32(loc_691_[1], loc_695_, 40);
					rt_store_i32(loc_691_, loc_695_, 4, loc_697_)
					rt_store_i32(loc_691_, loc_695_, 8, bit32_or(loc_697_ + bit32_or(loc_699_ - loc_698_, 0), 0))
					loc_698_ = buffer_read_i32(loc_691_[1], loc_695_, 44);
					if not (rt_equal_i32(loc_698_, 0)) then
						rt_store_i32(loc_691_, loc_695_, 4, bit32_or(loc_697_ + 1, 0))
						loc_697_ = rt_load_i32_from_u8(loc_691_, loc_697_, 0);
						rt_store_i32_into_i8(loc_691_, bit32_or(bit32_or(loc_696_ + loc_689_, 0) + -1, 0), 0, loc_697_)
					end
				else
					loc_697_ = loc_696_;
					loc_696_ = loc_689_;
					loc_695_, loc_698_ = loc_698_, loc_695_;
					loc_689_ = loc_699_;
				end
			else
				loc_697_ = loc_689_;
				loc_689_ = loc_699_;
				loc_699_ = loc_696_;
				loc_697_ = buffer_read_i32(loc_691_[1], loc_695_, 0);
				loc_699_ = 32;
				loc_696_ = 16;
				if rt_not_equal_i32(loc_689_, 0) then
					loc_689_ = loc_698_;
					loc_698_ = loc_697_;
					loc_697_ = loc_695_;
				else
					loc_689_ = loc_698_;
					loc_698_ = loc_697_;
					loc_697_ = loc_695_;
					loc_699_ = loc_696_;
				end
				rt_store_i32(loc_691_, loc_697_, 0, rt_or_i32(loc_698_, loc_699_))
			end
			loc_690_[1] = bit32_or(loc_692_ + 16, 0);
			return loc_689_, loc_688_
		end), "i32,i32,i32->i32")
	end)(module_locals[68], module_locals[69], module_locals[114], module_locals[3]);
	module_locals[71] = { nil };
	module_locals[71][1] = (function(loc_701_, loc_702_)
		return rt_function_type((function(loc_703_, loc_704_)
			local loc_705_, loc_706_, loc_707_
			loc_705_ = buffer_read_i32(loc_702_[1], loc_703_, 56);
			loc_707_ = loc_702_;
			loc_706_ = loc_704_;
			loc_706_ = loc_701_[1](loc_705_, loc_706_)
			return loc_706_, loc_705_
		end), "i32->i32")
	end)(module_locals[60], module_locals[3]);
	module_locals[72] = { nil };
	module_locals[76] = { nil };
	module_locals[72][1] = (function(loc_708_, loc_709_, loc_710_, loc_711_, loc_712_, loc_713_, loc_714_, loc_715_)
		return rt_function_type((function(loc_716_, loc_717_, loc_718_)
			local loc_719_, loc_720_, loc_721_, loc_722_, loc_723_, loc_724_, loc_725_, loc_726_, loc_727_, loc_728_, loc_729_, loc_730_, loc_731_, loc_732_, loc_733_, loc_734_, loc_735_
			loc_733_ = rt_load_i32_from_s8(loc_715_, loc_717_, 0);
			loc_722_ = loc_715_;
			loc_735_ = loc_714_[1];
			loc_721_ = loc_714_;
			loc_723_ = bit32_or(loc_735_ - 32, 0);
			loc_721_[1] = loc_723_;
			loc_735_ = loc_718_;
			loc_734_ = loc_711_[1](1094, loc_733_, 4, loc_735_)
			if rt_not_equal_i32(loc_734_, 0) then
				loc_724_ = loc_708_;
				loc_725_ = loc_709_;
				loc_726_ = loc_716_;
				loc_727_ = loc_711_;
				loc_728_ = loc_712_;
				loc_729_ = loc_713_;
				loc_730_ = loc_710_;
				loc_732_ = loc_717_;
				loc_719_ = loc_729_[1](1144, loc_735_)
				if rt_not_equal_i32(loc_719_, 0) then
					loc_731_ = 0;
					if not (rt_equal_i32(112, 0)) then
						rt_memory_fill(loc_722_, loc_719_, 0, 112)
					end
					loc_735_ = loc_728_[1](loc_732_, 43, loc_735_)
					if not (rt_not_equal_i32(loc_735_, 0)) then
						loc_735_ = loc_731_;
						loc_731_ = 8;
						loc_735_ = 4;
						if rt_equal_i32(loc_733_, 114) then
							loc_720_ = loc_719_;
						else
							loc_720_ = loc_719_;
							loc_731_ = loc_735_;
						end
						rt_store_i32(loc_722_, loc_720_, 0, loc_731_)
					end
					loc_734_ = loc_728_[1](loc_732_, 101, loc_734_)
					if not (rt_equal_i32(loc_734_, 0)) then
						loc_720_, loc_724_ = loc_724_, loc_720_;
						loc_724_, loc_733_ = loc_733_, loc_724_;
						loc_724_ = loc_720_;
						rt_store_i32(loc_722_, loc_723_, 16, 1)
						loc_733_ = loc_720_[1](loc_726_, 2, bit32_or(loc_723_ + 16, 0), loc_733_)
						loc_733_ = rt_load_i32_from_u8(loc_722_, loc_732_, 0);
					end
					if not (rt_not_equal_i32(rt_and_i32(loc_733_, 255), 97)) then
						loc_733_ = loc_720_;
						loc_732_ = loc_724_[1](loc_726_, 3, 0, loc_733_)
						if not (rt_not_equal_i32(rt_and_i32(loc_732_, 1), 0)) then
							loc_733_ = loc_732_;
							loc_732_ = loc_720_;
							loc_720_ = loc_724_;
							loc_724_ = loc_720_;
							rt_store_i32(loc_722_, loc_723_, 0, rt_or_i32(loc_733_, 1))
							loc_732_ = loc_720_[1](loc_726_, 4, loc_723_, loc_732_)
						end
						loc_731_ = rt_or_i32(loc_731_, 128);
						rt_store_i32(loc_722_, loc_719_, 0, loc_731_)
					end
					rt_store_i32(loc_722_, loc_719_, 64, -1)
					rt_store_i32(loc_722_, loc_719_, 44, 1024)
					rt_store_i32(loc_722_, loc_719_, 56, loc_726_)
					rt_store_i32(loc_722_, loc_719_, 40, bit32_or(loc_719_ + 120, 0))
					if not (rt_not_equal_i32(rt_and_i32(loc_731_, 8), 0)) then
						loc_726_ = loc_725_[1](loc_726_, loc_720_)
						if not (rt_equal_i32(loc_726_, 0)) then
							rt_store_i32(loc_722_, loc_719_, 64, 10)
						end
					end
					loc_726_ = loc_730_;
					rt_store_i32(loc_722_, loc_719_, 36, 1)
					rt_store_i32(loc_722_, loc_719_, 32, 2)
					rt_store_i32(loc_722_, loc_719_, 28, 3)
					rt_store_i32(loc_722_, loc_719_, 12, 4)
					loc_720_ = loc_730_[1](loc_719_, loc_720_)
				else
					loc_731_ = loc_719_;
					loc_734_ = loc_726_;
					loc_732_, loc_733_ = loc_733_, loc_732_;
					loc_726_ = loc_730_;
					loc_720_ = 0;
					loc_719_ = loc_735_;
				end
			else
				loc_724_ = loc_708_;
				loc_725_ = loc_709_;
				loc_727_ = loc_711_;
				loc_728_ = loc_712_;
				loc_729_ = loc_713_;
				loc_730_ = loc_710_;
				loc_732_ = loc_733_;
				loc_733_ = loc_717_;
				loc_734_ = loc_716_;
				loc_726_ = loc_730_;
				rt_store_i32(loc_722_, 0, 70852, 28)
				loc_720_ = 0;
				loc_719_ = loc_735_;
			end
			loc_721_[1] = bit32_or(loc_723_ + 32, 0);
			return loc_720_, loc_719_
		end), "i32,i32->i32")
	end)(module_locals[62], module_locals[63], module_locals[76], module_locals[85], module_locals[87], module_locals[106], module_locals[114], module_locals[3]);
	module_locals[73][1] = (function(loc_736_, loc_737_, loc_738_, loc_739_, loc_740_, loc_741_)
		return rt_function_type((function(loc_742_, loc_743_, loc_744_)
			local loc_745_, loc_746_, loc_747_, loc_748_, loc_749_, loc_750_, loc_751_, loc_752_, loc_753_, loc_754_
			loc_753_ = rt_load_i32_from_s8(loc_741_, loc_743_, 0);
			loc_747_ = loc_741_;
			loc_754_ = loc_744_;
			loc_754_ = loc_740_[1](1094, loc_753_, 4, loc_754_)
			if rt_not_equal_i32(loc_754_, 0) then
				loc_745_ = loc_742_;
				loc_748_ = loc_736_;
				loc_749_ = loc_737_;
				loc_750_ = loc_738_;
				loc_751_ = loc_739_;
				loc_752_ = loc_740_;
				loc_754_ = loc_743_;
				loc_746_ = loc_748_[1](loc_754_, loc_753_)
				loc_753_ = loc_750_[1](loc_745_, loc_746_, loc_753_)
				loc_746_ = 0;
				if not (rt_less_than_s32(loc_753_, 0)) then
					loc_746_ = loc_745_;
					loc_746_ = loc_751_[1](loc_753_, loc_754_, loc_746_)
					if rt_not_equal_i32(loc_746_, 0) then
						loc_754_ = loc_753_;
					else
						loc_754_ = loc_753_;
						loc_753_ = loc_746_;
						loc_746_ = loc_749_;
						loc_749_ = loc_746_;
						loc_753_ = loc_745_;
						loc_754_ = loc_746_[1](loc_754_, loc_753_)
						loc_746_ = 0;
					end
				end
			else
				loc_746_ = loc_743_;
				loc_748_ = loc_736_;
				loc_749_ = loc_737_;
				loc_750_ = loc_738_;
				loc_751_ = loc_739_;
				loc_752_ = loc_740_;
				loc_754_ = loc_742_;
				rt_store_i32(loc_747_, 0, 70852, 28)
				loc_746_ = 0;
				loc_745_ = loc_753_;
			end
			return loc_746_, loc_745_
		end), "i32,i32->i32")
	end)(module_locals[54], module_locals[60], module_locals[61], module_locals[72], module_locals[85], module_locals[3]);
	module_locals[74][1] = rt_function_type((function(loc_755_)
		local loc_756_
		loc_756_ = loc_755_;
		return 70880, loc_756_
	end), "->i32");
	module_locals[75][1] = rt_function_type((function(loc_757_)
		local loc_758_
		loc_758_ = loc_757_;
		return loc_758_
	end), "->");
	module_locals[76][1] = (function(loc_759_, loc_760_, loc_761_)
		return rt_function_type((function(loc_762_, loc_763_)
			local loc_764_, loc_765_, loc_766_, loc_767_, loc_768_, loc_769_, loc_770_
			loc_766_ = loc_761_;
			loc_770_ = loc_763_;
			loc_768_ = loc_759_[1](loc_770_)
			loc_770_ = buffer_read_i32(loc_766_[1], loc_768_, 0);
			rt_store_i32(loc_766_, loc_762_, 52, loc_770_)
			if rt_equal_i32(loc_770_, 0) then
				loc_765_ = loc_762_;
				loc_767_ = loc_760_;
				loc_769_ = loc_759_;
			else
				loc_765_ = loc_762_;
				loc_767_ = loc_760_;
				loc_769_ = loc_759_;
				rt_store_i32(loc_766_, loc_770_, 48, loc_765_)
			end
			rt_store_i32(loc_766_, loc_768_, 0, loc_765_)
			loc_767_[1](loc_764_)
			return loc_765_, loc_764_
		end), "i32->i32")
	end)(module_locals[74], module_locals[75], module_locals[3]);
	module_locals[100] = { nil };
	module_locals[77][1] = (function(loc_771_, loc_772_, loc_773_)
		return rt_function_type((function(loc_774_, loc_775_, loc_776_)
			local loc_777_, loc_778_, loc_779_, loc_780_, loc_781_
			loc_781_ = loc_772_[1];
			loc_779_ = loc_772_;
			loc_781_ = bit32_or(loc_781_ - 16, 0);
			loc_779_[1] = loc_781_;
			rt_store_i32(loc_773_, loc_781_, 12, loc_775_)
			loc_780_ = loc_773_;
			loc_778_ = loc_776_;
			loc_778_ = loc_771_[1](6472, loc_774_, loc_775_, loc_778_)
			loc_779_[1] = bit32_or(loc_781_ + 16, 0);
			return loc_778_, loc_777_
		end), "i32,i32->i32")
	end)(module_locals[100], module_locals[114], module_locals[3]);
	module_locals[78] = { nil };
	module_locals[78][1] = (function(loc_782_)
		return rt_function_type((function(loc_783_, loc_784_)
			local loc_785_, loc_786_, loc_787_, loc_788_, loc_789_
			loc_789_ = buffer_read_i32(loc_782_[1], loc_783_, 60);
			loc_787_ = loc_782_;
			rt_store_i32(loc_787_, loc_783_, 60, rt_or_i32(bit32_or(loc_789_ + -1, 0), loc_789_))
			loc_788_ = buffer_read_i32(loc_787_[1], loc_783_, 0);
			if rt_equal_i32(rt_and_i32(loc_788_, 8), 0) then
				loc_785_ = loc_784_;
				loc_789_ = loc_783_;
				rt_store_i64(loc_787_, loc_789_, 4, into_bits_i64(0, 0))
				loc_788_ = buffer_read_i32(loc_787_[1], loc_789_, 40);
				rt_store_i32(loc_787_, loc_789_, 24, loc_788_)
				rt_store_i32(loc_787_, loc_789_, 20, loc_788_)
				loc_786_ = buffer_read_i32(loc_787_[1], loc_789_, 44);
				rt_store_i32(loc_787_, loc_789_, 16, bit32_or(loc_788_ + loc_786_, 0))
				loc_786_ = 0;
			else
				loc_785_ = loc_784_;
				loc_789_ = loc_783_;
				rt_store_i32(loc_787_, loc_789_, 0, rt_or_i32(loc_788_, 32))
				loc_786_ = -1;
			end
			return loc_786_, loc_785_
		end), "i32->i32")
	end)(module_locals[3]);
	module_locals[79] = { nil };
	module_locals[79][1] = (function(loc_790_, loc_791_, loc_792_)
		return rt_function_type((function(loc_793_, loc_794_, loc_795_, loc_796_)
			local loc_797_, loc_798_, loc_799_, loc_800_, loc_801_, loc_802_, loc_803_, loc_804_, loc_805_, loc_806_, loc_807_, loc_808_
			loc_806_ = buffer_read_i32(loc_792_[1], loc_795_, 16);
			loc_800_ = loc_792_;
			loc_803_ = 0;
			loc_802_ = 0;
			if rt_not_equal_i32(loc_806_, 0) then
				loc_797_ = loc_796_;
				loc_798_ = loc_793_;
				loc_799_ = loc_791_;
				loc_801_ = loc_790_;
				loc_804_ = loc_794_;
				loc_805_ = loc_795_;
				loc_808_ = 0;
			else
				loc_797_ = loc_796_;
				loc_798_ = loc_793_;
				loc_799_ = loc_791_;
				loc_801_ = loc_790_;
				loc_804_ = loc_794_;
				loc_805_ = loc_795_;
				loc_808_ = loc_802_;
				loc_808_ = loc_797_;
				loc_808_ = loc_801_[1](loc_805_, loc_808_)
				loc_802_ = 0;
				if rt_not_equal_i32(loc_808_, 0) then
					loc_808_ = 1;
				else
					loc_808_ = loc_806_;
					loc_806_ = buffer_read_i32(loc_800_[1], loc_805_, 16);
					loc_808_ = 0;
				end
			end
			if rt_not_equal_i32(loc_808_, 0) then
				loc_803_ = 0;
			else
				loc_808_ = buffer_read_i32(loc_800_[1], loc_805_, 20);
				if rt_less_than_equal_u32(loc_804_, bit32_or(loc_806_ - loc_808_, 0)) then
					loc_806_ = loc_804_;
					loc_804_ = loc_808_;
					loc_807_ = loc_803_;
					loc_808_ = buffer_read_i32(loc_800_[1], loc_805_, 64);
					loc_803_ = 0;
					if rt_less_than_s32(loc_808_, 0) then
						loc_807_ = 0;
					else
						if rt_equal_i32(loc_806_, 0) then
							loc_807_ = 0;
						else
							loc_808_ = loc_797_;
							loc_798_, loc_803_ = loc_803_, loc_798_;
							loc_803_, loc_806_ = loc_806_, loc_803_;
							loc_806_, loc_802_ = loc_802_, loc_806_;
							loc_797_ = loc_807_;
							loc_798_ = loc_802_;
							loc_806_ = loc_803_;
							loc_807_ = 0;
							loc_803_ = bit32_or(loc_802_ + loc_803_, 0);
							loc_802_ = loc_808_;
							repeat
								rt_yield_budget = rt_yield_budget - 1
								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
								loc_808_ = loc_797_;
								loc_808_ = rt_load_i32_from_u8(loc_800_, bit32_or(bit32_or(loc_803_ + loc_807_, 0) + -1, 0), 0);
								if rt_equal_i32(loc_808_, 10) then
									loc_808_ = 0;
									loc_797_ = 1;
								else
									loc_807_ = bit32_or(loc_807_ + -1, 0);
									if rt_not_equal_i32(bit32_or(loc_806_ + loc_807_, 0), 0) then
										loc_808_ = 1;
										loc_797_ = 65535;
									else
										loc_808_ = 0;
										loc_797_ = 0;
									end
								end
							until loc_808_ == 0
							if rt_not_equal_i32(loc_797_, 0) then
								loc_803_ = buffer_read_i32(loc_800_[1], loc_805_, 32);
								loc_797_ = rt_table_get_function(loc_799_, loc_803_, "i32,i32,i32->i32");
								loc_803_ = bit32_or(loc_806_ + loc_807_, 0);
								loc_802_ = loc_797_(loc_805_, loc_798_, loc_803_, loc_802_)
								if rt_less_than_u32(loc_802_, loc_803_) then
									loc_807_ = 1;
								else
									loc_806_, loc_807_ = loc_807_, loc_806_;
									loc_804_ = buffer_read_i32(loc_800_[1], loc_805_, 20);
									loc_807_ = 0;
									loc_798_ = bit32_or(loc_803_ + loc_798_, 0);
									loc_806_ = bit32_or(0 - loc_806_, 0);
								end
							else
								loc_797_ = loc_802_;
								loc_807_ = 0;
								loc_802_ = loc_803_;
								loc_803_ = 0;
							end
						end
					end
					if rt_not_equal_i32(loc_807_, 0) then
						loc_803_ = 0;
					else
						if rt_equal_i32(loc_806_, 0) then
							loc_803_, loc_805_ = loc_805_, loc_803_;
							loc_805_, loc_806_ = loc_806_, loc_805_;
						else
							loc_803_, loc_805_ = loc_805_, loc_803_;
							loc_805_, loc_806_ = loc_806_, loc_805_;
							rt_memory_copy(loc_800_, loc_804_, loc_800_, loc_798_, loc_805_)
						end
						loc_804_ = buffer_read_i32(loc_800_[1], loc_803_, 20);
						rt_store_i32(loc_800_, loc_803_, 20, bit32_or(loc_804_ + loc_805_, 0))
						loc_803_ = 0;
						loc_802_ = bit32_or(loc_806_ + loc_805_, 0);
					end
				else
					loc_806_ = loc_804_;
					loc_807_ = loc_808_;
					loc_808_ = loc_803_;
					loc_808_ = buffer_read_i32(loc_800_[1], loc_805_, 32);
					loc_807_ = rt_table_get_function(loc_799_, loc_808_, "i32,i32,i32->i32");
					loc_808_ = loc_797_;
					loc_798_ = loc_807_(loc_805_, loc_798_, loc_806_, loc_808_)
					loc_803_ = 1;
				end
			end
			if not (rt_not_equal_i32(loc_803_, 0)) then
				loc_798_ = loc_802_;
			end
			return loc_798_, loc_797_
		end), "i32,i32,i32->i32")
	end)(module_locals[78], module_locals[112], module_locals[3]);
	module_locals[80] = { nil };
	module_locals[80][1] = (function(loc_809_, loc_810_, loc_811_)
		return rt_function_type((function(loc_812_, loc_813_, loc_814_, loc_815_, loc_816_)
			local loc_817_, loc_818_, loc_819_, loc_820_, loc_821_, loc_822_, loc_823_, loc_824_, loc_825_, loc_826_, loc_827_, loc_828_, loc_829_, loc_830_, loc_831_
			loc_828_ = buffer_read_i32(loc_811_[1], loc_815_, 16);
			loc_820_ = loc_811_;
			loc_825_ = 0;
			loc_824_ = rt_multiply_i32(loc_814_, loc_813_);
			loc_822_ = 0;
			if rt_not_equal_i32(loc_828_, 0) then
				loc_817_ = loc_816_;
				loc_818_ = loc_813_;
				loc_819_ = loc_810_;
				loc_821_ = loc_809_;
				loc_823_ = loc_814_;
				loc_826_ = loc_812_;
				loc_827_ = loc_815_;
				loc_831_ = 0;
			else
				loc_817_ = loc_816_;
				loc_818_ = loc_813_;
				loc_819_ = loc_810_;
				loc_821_ = loc_809_;
				loc_823_ = loc_814_;
				loc_826_ = loc_812_;
				loc_827_ = loc_815_;
				loc_831_ = loc_822_;
				loc_831_ = loc_817_;
				loc_831_ = loc_821_[1](loc_827_, loc_831_)
				loc_822_ = 0;
				if rt_not_equal_i32(loc_831_, 0) then
					loc_831_ = 1;
				else
					loc_831_ = loc_828_;
					loc_828_ = buffer_read_i32(loc_820_[1], loc_827_, 16);
					loc_831_ = 0;
				end
			end
			if not (rt_not_equal_i32(loc_831_, 0)) then
				loc_831_ = buffer_read_i32(loc_820_[1], loc_827_, 20);
				if rt_less_than_equal_u32(loc_824_, bit32_or(loc_828_ - loc_831_, 0)) then
					loc_828_ = loc_822_;
					loc_822_ = loc_825_;
					loc_825_ = loc_831_;
					loc_829_ = loc_824_;
					loc_830_ = loc_817_;
					loc_817_ = loc_826_;
					loc_824_ = 0;
					if rt_not_equal_i32(loc_829_, 0) then
						loc_831_ = buffer_read_i32(loc_820_[1], loc_827_, 64);
						loc_826_ = 0;
						if rt_greater_than_equal_s32(loc_831_, 0) then
							loc_828_ = loc_817_;
							loc_824_ = loc_829_;
							loc_829_ = bit32_or(loc_817_ + loc_829_, 0);
							repeat
								rt_yield_budget = rt_yield_budget - 1
								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
								loc_822_ = rt_load_i32_from_u8(loc_820_, bit32_or(bit32_or(loc_829_ + loc_826_, 0) + -1, 0), 0);
								if rt_equal_i32(loc_822_, 10) then
									loc_817_ = 0;
									loc_822_ = 1;
								else
									loc_826_ = bit32_or(loc_826_ + -1, 0);
									if rt_not_equal_i32(bit32_or(loc_824_ + loc_826_, 0), 0) then
										loc_817_ = 1;
										loc_822_ = 65535;
									else
										loc_817_ = 0;
										loc_822_ = 0;
									end
								end
							until loc_817_ == 0
							if rt_not_equal_i32(loc_822_, 0) then
								loc_829_ = buffer_read_i32(loc_820_[1], loc_827_, 32);
								loc_822_ = rt_table_get_function(loc_819_, loc_829_, "i32,i32,i32->i32");
								loc_829_ = bit32_or(loc_824_ + loc_826_, 0);
								loc_822_ = loc_822_(loc_827_, loc_828_, loc_829_, loc_830_)
								if rt_less_than_u32(loc_822_, loc_829_) then
									loc_830_ = 1;
								else
									loc_830_ = loc_825_;
									loc_825_ = buffer_read_i32(loc_820_[1], loc_827_, 20);
									loc_830_ = 0;
									loc_828_ = bit32_or(loc_829_ + loc_828_, 0);
									loc_826_ = bit32_or(0 - loc_826_, 0);
								end
							else
								loc_817_ = loc_830_;
								loc_830_ = loc_826_;
								loc_826_ = loc_824_;
								loc_830_ = 0;
								loc_824_ = loc_826_;
								loc_822_ = loc_829_;
								loc_829_ = 0;
							end
						else
							loc_817_, loc_830_ = loc_830_, loc_817_;
							loc_830_, loc_822_ = loc_822_, loc_830_;
							loc_822_, loc_828_ = loc_828_, loc_822_;
							loc_824_, loc_826_ = loc_826_, loc_824_;
							loc_826_, loc_829_ = loc_829_, loc_826_;
							loc_830_ = 0;
							loc_824_ = loc_826_;
						end
					else
						loc_826_ = loc_829_;
						loc_829_ = loc_824_;
						loc_831_ = loc_830_;
						loc_830_ = loc_822_;
						loc_822_ = loc_828_;
						loc_830_ = 0;
						loc_828_ = loc_817_;
						loc_824_ = loc_826_;
						loc_817_ = loc_831_;
					end
					if not (rt_not_equal_i32(loc_830_, 0)) then
						if rt_equal_i32(loc_826_, 0) then
							loc_826_, loc_827_ = loc_827_, loc_826_;
							loc_827_, loc_828_ = loc_828_, loc_827_;
						else
							loc_826_, loc_827_ = loc_827_, loc_826_;
							loc_827_, loc_828_ = loc_828_, loc_827_;
							rt_memory_copy(loc_820_, loc_825_, loc_820_, loc_827_, loc_828_)
						end
						loc_827_ = buffer_read_i32(loc_820_[1], loc_826_, 20);
						rt_store_i32(loc_820_, loc_826_, 20, bit32_or(loc_827_ + loc_828_, 0))
						loc_822_ = bit32_or(loc_829_ + loc_828_, 0);
					end
				else
					loc_828_ = loc_822_;
					loc_829_ = loc_824_;
					loc_830_ = loc_825_;
					loc_817_, loc_826_ = loc_826_, loc_817_;
					loc_826_, loc_831_ = loc_831_, loc_826_;
					loc_830_ = buffer_read_i32(loc_820_[1], loc_827_, 32);
					loc_830_ = rt_table_get_function(loc_819_, loc_830_, "i32,i32,i32->i32");
					loc_822_ = loc_830_(loc_827_, loc_817_, loc_829_, loc_831_)
					loc_824_ = loc_829_;
				end
			end
			if rt_not_equal_i32(loc_822_, loc_824_) then
				loc_822_ = rt_divide_u32(loc_822_, loc_818_);
				loc_818_ = loc_822_;
			else
				loc_822_ = 0;
				if rt_not_equal_i32(loc_818_, 0) then
					loc_818_ = loc_823_;
					loc_823_ = loc_822_;
				else
					loc_822_, loc_823_ = loc_823_, loc_822_;
					loc_818_ = loc_823_;
				end
			end
			return loc_818_, loc_817_
		end), "i32,i32,i32,i32->i32")
	end)(module_locals[78], module_locals[112], module_locals[3]);
	module_locals[81] = { nil };
	module_locals[81][1] = (function(loc_832_, loc_833_)
		return rt_function_type((function(loc_834_, loc_835_, loc_836_)
			local loc_837_, loc_838_, loc_839_, loc_840_, loc_841_
			loc_838_ = -1;
			loc_841_ = 0;
			loc_840_ = loc_836_;
			loc_839_ = loc_833_[1](loc_834_, loc_840_)
			loc_840_ = loc_832_[1](loc_834_, 1, loc_839_, loc_835_, loc_840_)
			if rt_not_equal_i32(loc_839_, loc_840_) then
				loc_839_ = loc_832_;
				loc_840_ = loc_833_;
			else
				loc_839_ = loc_832_;
				loc_840_ = loc_833_;
				loc_838_ = loc_841_;
			end
			return loc_838_, loc_837_
		end), "i32,i32->i32")
	end)(module_locals[80], module_locals[91]);
	module_locals[82] = { nil };
	module_locals[82][1] = (function(loc_842_, loc_843_, loc_844_, loc_845_)
		return rt_function_type((function(loc_846_, loc_847_, loc_848_)
			local loc_849_, loc_850_, loc_851_, loc_852_, loc_853_, loc_854_, loc_855_, loc_856_, loc_857_, loc_858_, loc_859_
			loc_859_ = loc_843_[1];
			loc_851_ = loc_843_;
			loc_854_ = bit32_or(loc_859_ - 16, 0);
			loc_851_[1] = loc_854_;
			rt_store_i32_into_i8(loc_845_, loc_854_, 15, loc_847_)
			loc_853_ = loc_845_;
			loc_850_ = buffer_read_i32(loc_853_[1], loc_846_, 16);
			if rt_not_equal_i32(loc_850_, 0) then
				loc_849_ = loc_848_;
				loc_852_ = loc_844_;
				loc_855_ = loc_842_;
				loc_856_ = loc_846_;
				loc_857_ = loc_847_;
				loc_859_ = 0;
			else
				loc_849_ = loc_848_;
				loc_852_ = loc_844_;
				loc_855_ = loc_842_;
				loc_856_ = loc_846_;
				loc_857_ = loc_847_;
				loc_859_ = loc_850_;
				loc_859_ = loc_849_;
				loc_859_ = loc_855_[1](loc_856_, loc_859_)
				if rt_equal_i32(loc_859_, 0) then
					loc_850_ = buffer_read_i32(loc_853_[1], loc_856_, 16);
					loc_859_ = 0;
				else
					loc_859_ = 1;
					loc_850_ = -1;
				end
			end
			if not (rt_not_equal_i32(loc_859_, 0)) then
				loc_858_ = buffer_read_i32(loc_853_[1], loc_856_, 20);
				if rt_equal_i32(loc_858_, loc_850_) then
					loc_856_, loc_857_ = loc_857_, loc_856_;
					loc_856_ = 0;
				else
					loc_859_ = loc_850_;
					loc_856_, loc_857_ = loc_857_, loc_856_;
					loc_859_ = buffer_read_i32(loc_853_[1], loc_857_, 64);
					loc_850_ = rt_and_i32(loc_856_, 255);
					if rt_equal_i32(loc_859_, loc_850_) then
						loc_856_, loc_858_ = loc_858_, loc_856_;
						loc_856_ = 0;
					else
						loc_856_, loc_858_ = loc_858_, loc_856_;
						rt_store_i32(loc_853_, loc_857_, 20, bit32_or(loc_856_ + 1, 0))
						rt_store_i32_into_i8(loc_853_, loc_856_, 0, loc_858_)
						loc_856_ = 1;
					end
				end
				if not (rt_not_equal_i32(loc_856_, 0)) then
					loc_856_ = loc_850_;
					loc_856_ = buffer_read_i32(loc_853_[1], loc_857_, 32);
					loc_850_ = rt_table_get_function(loc_852_, loc_856_, "i32,i32,i32->i32");
					loc_856_ = loc_849_;
					loc_857_ = loc_850_(loc_857_, bit32_or(loc_854_ + 15, 0), 1, loc_856_)
					if rt_equal_i32(loc_857_, 1) then
						loc_850_ = rt_load_i32_from_u8(loc_853_, loc_854_, 15);
					else
						loc_850_ = -1;
					end
				end
			end
			loc_851_[1] = bit32_or(loc_854_ + 16, 0);
			return loc_850_, loc_849_
		end), "i32,i32->i32")
	end)(module_locals[78], module_locals[114], module_locals[112], module_locals[3]);
	module_locals[83][1] = (function(loc_860_, loc_861_, loc_862_)
		return rt_function_type((function(loc_863_, loc_864_)
			local loc_865_, loc_866_, loc_867_, loc_868_, loc_869_, loc_870_
			loc_867_ = loc_862_;
			loc_870_ = loc_864_;
			loc_870_ = loc_860_[1](loc_863_, 6472, loc_870_)
			if rt_greater_than_equal_s32(loc_870_, 0) then
				loc_866_ = loc_863_;
				loc_868_ = loc_860_;
				loc_869_ = loc_861_;
				loc_870_ = buffer_read_i32(loc_867_[1], 0, 6536);
				if rt_equal_i32(loc_870_, 10) then
					loc_870_ = 0;
				else
					loc_870_ = loc_866_;
					loc_866_ = buffer_read_i32(loc_867_[1], 0, 6492);
					loc_870_ = buffer_read_i32(loc_867_[1], 0, 6488);
					if rt_equal_i32(loc_866_, loc_870_) then
						loc_870_ = 0;
					else
						rt_store_i32(loc_867_, 0, 6492, bit32_or(loc_866_ + 1, 0))
						rt_store_i32_into_i8(loc_867_, loc_866_, 0, 10)
						loc_870_ = 1;
						loc_866_ = 0;
					end
				end
				if not (rt_not_equal_i32(loc_870_, 0)) then
					loc_865_, loc_869_ = loc_869_, loc_865_;
					loc_869_, loc_866_ = loc_866_, loc_869_;
					loc_869_ = loc_865_;
					loc_866_ = loc_865_[1](6472, 10, loc_866_)
					loc_866_ = rt_shift_right_s32(loc_866_, 31);
				end
			else
				loc_868_ = loc_860_;
				loc_869_ = loc_861_;
				loc_870_ = loc_863_;
				loc_866_ = -1;
			end
			return loc_866_, loc_865_
		end), "i32->i32")
	end)(module_locals[81], module_locals[82], module_locals[3]);
	module_locals[84] = { nil };
	module_locals[84][1] = (function(loc_871_, loc_872_, loc_873_)
		return rt_function_type((function(loc_874_, loc_875_, loc_876_, loc_877_)
			local loc_878_, loc_879_, loc_880_, loc_881_, loc_882_, loc_883_, loc_884_, loc_885_
			rt_store_i32(loc_873_, loc_874_, 32, 2)
			loc_880_ = loc_873_;
			loc_885_ = rt_load_i32_from_u8(loc_880_, loc_874_, 0);
			if rt_not_equal_i32(rt_and_i32(loc_885_, 64), 0) then
				loc_878_ = loc_876_;
				loc_879_ = loc_877_;
				loc_881_ = loc_875_;
				loc_882_ = loc_874_;
				loc_883_ = loc_872_;
				loc_884_ = loc_871_;
			else
				loc_878_ = loc_876_;
				loc_881_ = loc_875_;
				loc_882_ = loc_874_;
				loc_883_ = loc_872_;
				loc_884_ = loc_871_;
				loc_885_ = loc_877_;
				loc_879_ = buffer_read_i32(loc_880_[1], loc_882_, 56);
				loc_885_ = loc_884_[1](loc_879_, loc_885_)
				if not (rt_not_equal_i32(loc_885_, 0)) then
					rt_store_i32(loc_880_, loc_882_, 64, -1)
				end
			end
			loc_879_ = loc_883_[1](loc_882_, loc_881_, loc_878_, loc_879_)
			return loc_879_, loc_878_
		end), "i32,i32,i32->i32")
	end)(module_locals[63], module_locals[67], module_locals[3]);
	module_locals[85][1] = (function(loc_886_)
		return rt_function_type((function(loc_887_, loc_888_, loc_889_, loc_890_)
			local loc_891_, loc_892_, loc_893_, loc_894_, loc_895_, loc_896_, loc_897_, loc_898_, loc_899_, loc_900_
			loc_894_ = 0;
			loc_898_ = (rt_not_equal_i32(loc_889_, 0) and 1 or 0);
			loc_896_ = 0;
			loc_897_ = 0;
			if rt_equal_i32(rt_and_i32(loc_887_, 3), 0) then
				loc_891_ = loc_890_;
				loc_892_ = loc_887_;
				loc_893_ = loc_886_;
				loc_895_ = loc_888_;
				loc_899_ = loc_889_;
				loc_900_ = 0;
			else
				loc_891_ = loc_890_;
				loc_892_ = loc_887_;
				loc_893_ = loc_886_;
				loc_895_ = loc_888_;
				loc_899_ = loc_889_;
				if rt_equal_i32(loc_899_, 0) then
					loc_900_ = 0;
				else
					loc_900_ = loc_896_;
					loc_900_ = rt_load_i32_from_u8(loc_893_, loc_892_, 0);
					if rt_not_equal_i32(loc_900_, rt_and_i32(loc_895_, 255)) then
						loc_900_ = loc_898_;
						loc_897_ = bit32_or(loc_899_ + -1, 0);
						loc_898_ = (rt_not_equal_i32(loc_897_, 0) and 1 or 0);
						loc_896_ = bit32_or(loc_892_ + 1, 0);
						if rt_equal_i32(rt_and_i32(loc_896_, 3), 0) then
							loc_900_ = 1;
						else
							if rt_equal_i32(loc_897_, 0) then
								loc_900_ = 1;
							else
								loc_900_ = rt_load_i32_from_u8(loc_893_, loc_896_, 0);
								if rt_equal_i32(loc_900_, rt_and_i32(loc_895_, 255)) then
									loc_900_ = 2;
								else
									loc_900_ = loc_898_;
									loc_898_ = loc_896_;
									loc_897_ = bit32_or(loc_899_ + -2, 0);
									loc_898_ = (rt_not_equal_i32(loc_897_, 0) and 1 or 0);
									loc_896_ = bit32_or(loc_892_ + 2, 0);
									if rt_equal_i32(rt_and_i32(loc_896_, 3), 0) then
										loc_900_ = 1;
									else
										if rt_equal_i32(loc_897_, 0) then
											loc_900_ = 1;
										else
											loc_900_ = rt_load_i32_from_u8(loc_893_, loc_896_, 0);
											if rt_equal_i32(loc_900_, rt_and_i32(loc_895_, 255)) then
												loc_900_ = 2;
											else
												loc_900_ = loc_898_;
												loc_898_ = loc_896_;
												loc_897_ = bit32_or(loc_899_ + -3, 0);
												loc_898_ = (rt_not_equal_i32(loc_897_, 0) and 1 or 0);
												loc_896_ = bit32_or(loc_892_ + 3, 0);
												if rt_equal_i32(rt_and_i32(loc_896_, 3), 0) then
													loc_900_ = 1;
												else
													if rt_equal_i32(loc_897_, 0) then
														loc_900_ = 1;
													else
														loc_900_ = rt_load_i32_from_u8(loc_893_, loc_896_, 0);
														if rt_equal_i32(loc_900_, rt_and_i32(loc_895_, 255)) then
															loc_900_ = 2;
														else
															loc_900_ = loc_898_;
															loc_898_ = loc_899_;
															loc_899_ = loc_896_;
															loc_896_ = loc_892_;
															loc_900_ = 1;
															loc_892_ = loc_896_;
															loc_899_ = loc_898_;
															loc_897_ = bit32_or(loc_898_ + -4, 0);
															loc_898_ = (rt_not_equal_i32(loc_897_, 0) and 1 or 0);
															loc_896_ = bit32_or(loc_896_ + 4, 0);
														end
													end
												end
											end
										end
									end
								end
							end
						end
					else
						loc_896_ = loc_892_;
						loc_897_ = loc_899_;
						loc_900_ = 2;
						loc_892_ = loc_896_;
						loc_899_ = loc_897_;
					end
				end
			end
			if (loc_900_) >= 0 and (loc_900_) < 2 then
				if (loc_900_) < 1 then
					loc_892_, loc_897_ = loc_897_, loc_892_;
					loc_897_, loc_899_ = loc_899_, loc_897_;
					loc_899_, loc_896_ = loc_896_, loc_899_;
					loc_899_ = 0;
					loc_892_ = loc_896_;
				else
					loc_899_ = 0;
				end
			else
				loc_899_ = 1;
			end
			if rt_not_equal_i32(loc_899_, 0) then
				loc_898_ = 0;
			else
				if rt_equal_i32(loc_898_, 0) then
					loc_898_ = 1;
				else
					loc_898_ = rt_load_i32_from_u8(loc_893_, loc_896_, 0);
					if rt_equal_i32(loc_898_, rt_and_i32(loc_895_, 255)) then
						loc_898_ = 0;
					else
						if rt_less_than_u32(loc_897_, 4) then
							loc_898_ = 0;
						else
							loc_898_ = loc_892_;
							loc_892_ = rt_multiply_i32(rt_and_i32(loc_895_, 255), 16843009);
							repeat
								rt_yield_budget = rt_yield_budget - 1
								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
								loc_898_ = loc_894_;
								loc_898_ = buffer_read_i32(loc_893_[1], loc_896_, 0);
								loc_898_ = rt_exclusive_or_i32(loc_898_, loc_892_);
								if rt_not_equal_i32(rt_and_i32(rt_or_i32(bit32_or(16843008 - loc_898_, 0), loc_898_), -2139062144), -2139062144) then
									loc_898_ = 0;
									loc_894_ = 1;
								else
									loc_896_ = bit32_or(loc_896_ + 4, 0);
									loc_897_ = bit32_or(loc_897_ + -4, 0);
									if rt_greater_than_u32(loc_897_, 3) then
										loc_898_ = 1;
										loc_894_ = 65535;
									else
										loc_898_ = 0;
										loc_894_ = 0;
									end
								end
							until loc_898_ == 0
							if rt_not_equal_i32(loc_894_, 0) then
								loc_898_ = 1;
							else
								loc_898_ = 0;
							end
						end
					end
					if rt_not_equal_i32(loc_898_, 0) then
						loc_898_ = 0;
					else
						if rt_equal_i32(loc_897_, 0) then
							loc_898_ = 1;
						else
							loc_898_ = 0;
						end
					end
				end
			end
			if rt_not_equal_i32(loc_898_, 0) then
				loc_894_ = 0;
			else
				loc_898_ = loc_897_;
				loc_897_ = loc_896_;
				loc_896_ = loc_894_;
				loc_895_ = rt_and_i32(loc_895_, 255);
				loc_894_ = loc_898_;
				repeat
					rt_yield_budget = rt_yield_budget - 1
					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
					loc_898_ = loc_896_;
					loc_898_ = rt_load_i32_from_u8(loc_893_, loc_897_, 0);
					if rt_not_equal_i32(loc_898_, loc_895_) then
						loc_898_ = loc_894_;
						loc_897_ = bit32_or(loc_897_ + 1, 0);
						loc_894_ = bit32_or(loc_898_ + -1, 0);
						if rt_not_equal_i32(loc_894_, 0) then
							loc_898_ = 1;
							loc_896_ = 65535;
						else
							loc_898_ = 0;
							loc_896_ = 1;
						end
					else
						loc_898_ = 0;
						loc_896_ = 0;
					end
				until loc_898_ == 0
				if rt_not_equal_i32(loc_896_, 0) then
					loc_894_ = 0;
				else
					loc_896_ = loc_892_;
					loc_894_ = 1;
					loc_892_ = loc_897_;
				end
			end
			if not (rt_not_equal_i32(loc_894_, 0)) then
				loc_892_ = 0;
			end
			return loc_892_, loc_891_
		end), "i32,i32,i32->i32")
	end)(module_locals[3]);
	module_locals[86][1] = (function(loc_901_)
		return rt_function_type((function(loc_902_, loc_903_, loc_904_, loc_905_)
			local loc_906_, loc_907_, loc_908_, loc_909_, loc_910_, loc_911_, loc_912_, loc_913_, loc_914_, loc_915_
			loc_909_ = 0;
			loc_907_ = 0;
			loc_913_ = 0;
			loc_914_ = 0;
			if rt_equal_i32(loc_904_, 0) then
				loc_906_ = loc_905_;
				loc_908_ = loc_901_;
				loc_910_ = loc_902_;
				loc_911_ = loc_903_;
				loc_912_ = loc_904_;
			else
				loc_906_ = loc_905_;
				loc_908_ = loc_901_;
				loc_910_ = loc_902_;
				loc_911_ = loc_909_;
				loc_909_ = loc_903_;
				loc_912_ = loc_904_;
				loc_915_ = loc_907_;
				loc_907_ = loc_912_;
				loc_912_ = loc_915_;
				repeat
					rt_yield_budget = rt_yield_budget - 1
					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
					loc_915_ = loc_911_;
					loc_913_, loc_914_ = loc_914_, loc_913_;
					loc_913_ = rt_load_i32_from_u8(loc_908_, loc_910_, 0);
					loc_914_ = rt_load_i32_from_u8(loc_908_, loc_909_, 0);
					if rt_not_equal_i32(loc_913_, loc_914_) then
						loc_915_ = 0;
						loc_911_ = 1;
					else
						loc_910_ = bit32_or(loc_910_ + 1, 0);
						loc_909_ = bit32_or(loc_909_ + 1, 0);
						loc_907_ = bit32_or(loc_907_ + -1, 0);
						if rt_not_equal_i32(loc_907_, 0) then
							loc_915_ = 1;
							loc_911_ = 65535;
						else
							loc_915_ = 0;
							loc_911_ = 0;
						end
					end
				until loc_915_ == 0
				if rt_not_equal_i32(loc_911_, 0) then
					loc_907_ = bit32_or(loc_913_ - loc_914_, 0);
				else
					loc_913_, loc_914_ = loc_914_, loc_913_;
					loc_907_ = loc_912_;
				end
			end
			return loc_907_, loc_906_
		end), "i32,i32,i32->i32")
	end)(module_locals[3]);
	module_locals[88] = { nil };
	module_locals[87][1] = (function(loc_916_, loc_917_)
		return rt_function_type((function(loc_918_, loc_919_, loc_920_)
			local loc_921_, loc_922_, loc_923_, loc_924_, loc_925_
			loc_923_ = loc_917_;
			loc_925_ = loc_920_;
			loc_922_ = loc_916_[1](loc_918_, loc_919_, loc_925_)
			loc_924_ = rt_load_i32_from_u8(loc_923_, loc_922_, 0);
			loc_925_ = 0;
			if rt_equal_i32(loc_924_, rt_and_i32(loc_919_, 255)) then
				loc_924_ = loc_916_;
			else
				loc_924_ = loc_916_;
				loc_922_ = loc_925_;
			end
			return loc_922_, loc_921_
		end), "i32,i32->i32")
	end)(module_locals[88], module_locals[3]);
	module_locals[88][1] = (function(loc_926_, loc_927_)
		return rt_function_type((function(loc_928_, loc_929_, loc_930_)
			local loc_931_, loc_932_, loc_933_, loc_934_, loc_935_, loc_936_, loc_937_, loc_938_, loc_939_
			loc_934_ = 0;
			loc_937_ = rt_and_i32(loc_929_, 255);
			loc_938_ = 0;
			if rt_equal_i32(loc_937_, 0) then
				loc_931_ = loc_926_;
				loc_932_ = loc_930_;
				loc_933_ = loc_927_;
				loc_935_ = loc_928_;
				loc_936_ = loc_929_;
				loc_934_ = loc_931_;
				loc_932_ = loc_931_[1](loc_935_, loc_932_)
				loc_932_ = bit32_or(loc_935_ + loc_932_, 0);
			else
				loc_931_ = loc_926_;
				loc_932_ = loc_930_;
				loc_933_ = loc_927_;
				loc_935_ = loc_928_;
				loc_936_ = loc_929_;
				if rt_equal_i32(rt_and_i32(loc_935_, 3), 0) then
					loc_931_, loc_932_ = loc_932_, loc_931_;
					loc_932_, loc_935_ = loc_935_, loc_932_;
					loc_935_, loc_937_ = loc_937_, loc_935_;
					loc_937_, loc_934_ = loc_934_, loc_937_;
					loc_939_ = 0;
				else
					loc_939_ = loc_938_;
					loc_931_, loc_932_ = loc_932_, loc_931_;
					loc_932_, loc_935_ = loc_935_, loc_932_;
					loc_935_, loc_937_ = loc_937_, loc_935_;
					loc_937_, loc_934_ = loc_934_, loc_937_;
					loc_939_ = rt_load_i32_from_u8(loc_933_, loc_932_, 0);
					if rt_not_equal_i32(loc_939_, 0) then
						if rt_not_equal_i32(loc_939_, rt_and_i32(loc_936_, 255)) then
							loc_938_ = bit32_or(loc_932_ + 1, 0);
							if rt_not_equal_i32(rt_and_i32(loc_938_, 3), 0) then
								loc_939_ = rt_load_i32_from_u8(loc_933_, loc_938_, 0);
								if rt_equal_i32(loc_939_, 0) then
									loc_939_ = 1;
								else
									if rt_equal_i32(loc_939_, rt_and_i32(loc_936_, 255)) then
										loc_939_ = 1;
									else
										loc_939_ = loc_938_;
										loc_938_ = bit32_or(loc_932_ + 2, 0);
										if rt_not_equal_i32(rt_and_i32(loc_938_, 3), 0) then
											loc_939_ = rt_load_i32_from_u8(loc_933_, loc_938_, 0);
											if rt_equal_i32(loc_939_, 0) then
												loc_939_ = 1;
											else
												if rt_equal_i32(loc_939_, rt_and_i32(loc_936_, 255)) then
													loc_939_ = 1;
												else
													loc_939_ = loc_938_;
													loc_938_ = bit32_or(loc_932_ + 3, 0);
													if rt_not_equal_i32(rt_and_i32(loc_938_, 3), 0) then
														loc_939_ = rt_load_i32_from_u8(loc_933_, loc_938_, 0);
														if rt_equal_i32(loc_939_, 0) then
															loc_939_ = 1;
														else
															if rt_equal_i32(loc_939_, rt_and_i32(loc_936_, 255)) then
																loc_939_ = 1;
															else
																loc_939_ = 0;
																loc_932_ = bit32_or(loc_932_ + 4, 0);
															end
														end
													else
														loc_939_ = loc_932_;
														loc_939_ = 0;
														loc_932_ = loc_938_;
													end
												end
											end
										else
											loc_939_ = loc_932_;
											loc_939_ = 0;
											loc_932_ = loc_938_;
										end
									end
								end
							else
								loc_939_ = loc_932_;
								loc_939_ = 0;
								loc_932_ = loc_938_;
							end
						else
							loc_938_ = loc_939_;
							loc_939_ = 2;
						end
					else
						loc_938_ = loc_939_;
						loc_939_ = 2;
					end
				end
				if (loc_939_) >= 0 and (loc_939_) < 2 then
					if (loc_939_) < 1 then
						loc_939_ = loc_938_;
						loc_939_ = buffer_read_i32(loc_933_[1], loc_932_, 0);
						if rt_not_equal_i32(rt_and_i32(rt_or_i32(bit32_or(16843008 - loc_939_, 0), loc_939_), -2139062144), -2139062144) then
							loc_938_ = loc_932_;
							loc_932_ = loc_939_;
						else
							loc_938_ = loc_932_;
							loc_932_ = loc_939_;
							loc_935_ = rt_multiply_i32(loc_935_, 16843009);
							repeat
								rt_yield_budget = rt_yield_budget - 1
								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
								loc_939_ = loc_937_;
								loc_932_ = rt_exclusive_or_i32(loc_932_, loc_935_);
								if rt_not_equal_i32(rt_and_i32(rt_or_i32(bit32_or(16843008 - loc_932_, 0), loc_932_), -2139062144), -2139062144) then
									loc_939_ = 0;
									loc_937_ = 1;
								else
									loc_939_ = loc_932_;
									loc_938_ = bit32_or(loc_938_ + 4, 0);
									loc_932_ = buffer_read_i32(loc_933_[1], loc_938_, 0);
									if rt_equal_i32(rt_and_i32(rt_or_i32(bit32_or(16843008 - loc_932_, 0), loc_932_), -2139062144), -2139062144) then
										loc_939_ = 1;
										loc_937_ = 65535;
									else
										loc_939_ = 0;
										loc_937_ = 0;
									end
								end
							until loc_939_ == 0
							if rt_not_equal_i32(loc_937_, 0) then
							end
						end
						loc_932_ = loc_938_;
						loc_938_ = bit32_or(loc_938_ + -1, 0);
						repeat
							rt_yield_budget = rt_yield_budget - 1
							if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
							loc_935_ = loc_932_;
							loc_938_ = bit32_or(loc_938_ + 1, 0);
							loc_932_ = rt_load_i32_from_u8(loc_933_, loc_938_, 0);
							if rt_equal_i32(loc_932_, 0) then
								loc_935_ = 0;
								loc_937_ = 1;
							else
								if rt_not_equal_i32(loc_932_, rt_and_i32(loc_936_, 255)) then
									loc_935_ = 1;
									loc_937_ = 65535;
								else
									loc_935_ = 0;
									loc_937_ = 0;
								end
							end
						until loc_935_ == 0
						if rt_not_equal_i32(loc_937_, 0) then
							loc_937_ = 0;
						else
							loc_937_ = 0;
						end
					else
						loc_937_ = 0;
					end
				else
					loc_937_ = 1;
				end
				if not (rt_not_equal_i32(loc_937_, 0)) then
					loc_937_ = loc_932_;
					loc_932_ = loc_938_;
				end
			end
			return loc_932_, loc_931_
		end), "i32,i32->i32")
	end)(module_locals[91], module_locals[3]);
	module_locals[89][1] = (function(loc_940_, loc_941_, loc_942_)
		return rt_function_type((function(loc_943_, loc_944_, loc_945_)
			local loc_946_, loc_947_, loc_948_, loc_949_, loc_950_, loc_951_, loc_952_, loc_953_, loc_954_, loc_955_, loc_956_
			loc_956_ = loc_941_[1];
			loc_949_ = loc_941_;
			loc_951_ = bit32_or(loc_956_ - 32, 0);
			loc_949_[1] = loc_951_;
			loc_953_ = rt_load_i32_from_u8(loc_942_, loc_944_, 0);
			loc_950_ = loc_942_;
			loc_954_ = 0;
			if rt_equal_i32(loc_953_, 0) then
				loc_946_ = loc_945_;
				loc_947_ = loc_944_;
				loc_948_ = loc_943_;
				loc_952_ = loc_940_;
				loc_954_ = 0;
			else
				loc_946_ = loc_945_;
				loc_947_ = loc_944_;
				loc_948_ = loc_943_;
				loc_952_ = loc_940_;
				loc_956_ = rt_load_i32_from_u8(loc_950_, loc_947_, 1);
				if rt_not_equal_i32(loc_956_, 0) then
					loc_956_ = loc_947_;
					loc_947_ = loc_948_;
					rt_store_i64(loc_950_, bit32_or(loc_951_ + 24, 0), 0, into_bits_i64(0, 0))
					rt_store_i64(loc_950_, bit32_or(loc_951_ + 16, 0), 0, into_bits_i64(0, 0))
					rt_store_i64(loc_950_, loc_951_, 8, into_bits_i64(0, 0))
					rt_store_i64(loc_950_, loc_951_, 0, into_bits_i64(0, 0))
					loc_955_ = bit32_or(loc_956_ + 1, 0);
					repeat
						rt_yield_budget = rt_yield_budget - 1
						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
						loc_956_ = bit32_or(loc_951_ + rt_and_i32(rt_shift_right_u32(loc_953_, 3), 28), 0);
						loc_948_ = buffer_read_i32(loc_950_[1], loc_956_, 0);
						rt_store_i32(loc_950_, loc_956_, 0, rt_or_i32(loc_948_, rt_shift_left_i32(1, loc_953_)))
						loc_948_ = rt_load_i32_from_u8(loc_950_, loc_955_, 0);
						loc_955_ = bit32_or(loc_955_ + 1, 0);
						loc_953_ = loc_948_;
					until loc_948_ == 0
					loc_953_ = rt_load_i32_from_u8(loc_950_, loc_947_, 0);
					if rt_equal_i32(loc_953_, 0) then
						loc_948_ = loc_947_;
						loc_954_ = 1;
					else
						loc_948_ = loc_947_;
						loc_955_ = loc_947_;
						loc_948_ = loc_955_;
						loc_947_ = loc_955_;
						repeat
							rt_yield_budget = rt_yield_budget - 1
							if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
							loc_955_ = loc_954_;
							loc_955_ = buffer_read_i32(loc_950_[1], bit32_or(loc_951_ + rt_and_i32(rt_shift_right_u32(loc_953_, 3), 28), 0), 0);
							if rt_not_equal_i32(rt_and_i32(rt_shift_right_u32(loc_955_, loc_953_), 1), 0) then
								loc_955_ = 0;
								loc_954_ = 1;
							else
								loc_955_ = loc_953_;
								loc_947_ = bit32_or(loc_947_ + 1, 0);
								loc_953_ = rt_load_i32_from_u8(loc_950_, loc_947_, 0);
								if rt_not_equal_i32(loc_953_, 0) then
									loc_955_ = 1;
									loc_954_ = 65535;
								else
									loc_955_ = 0;
									loc_954_ = 0;
								end
							end
						until loc_955_ == 0
						if rt_not_equal_i32(loc_954_, 0) then
							loc_954_ = 1;
						else
							loc_954_ = 1;
						end
					end
				else
					loc_955_ = loc_954_;
					loc_956_ = loc_947_;
					loc_947_ = loc_948_;
					loc_954_ = 0;
					loc_948_ = loc_947_;
					loc_947_ = loc_956_;
				end
			end
			if not (rt_not_equal_i32(loc_954_, 0)) then
				loc_946_, loc_952_ = loc_952_, loc_946_;
				loc_952_, loc_947_ = loc_947_, loc_952_;
				loc_952_ = loc_946_;
				loc_947_ = loc_946_[1](loc_948_, rt_extend_s8_to_i32(loc_953_), loc_947_)
			end
			loc_949_[1] = bit32_or(loc_951_ + 32, 0);
			return bit32_or(loc_947_ - loc_948_, 0), loc_946_
		end), "i32,i32->i32")
	end)(module_locals[88], module_locals[114], module_locals[3]);
	module_locals[90][1] = (function(loc_957_, loc_958_, loc_959_)
		return rt_function_type((function(loc_960_, loc_961_)
			local loc_962_, loc_963_, loc_964_, loc_965_, loc_966_, loc_967_, loc_968_
			loc_964_ = loc_959_;
			loc_968_ = loc_961_;
			loc_968_ = loc_957_[1](loc_960_, loc_968_)
			loc_968_ = bit32_or(loc_968_ + 1, 0);
			loc_963_ = loc_958_[1](loc_968_, loc_967_)
			if rt_equal_i32(loc_963_, 0) then
				loc_965_ = loc_957_;
				loc_966_ = loc_958_;
				loc_967_ = loc_960_;
			else
				loc_965_ = loc_957_;
				loc_966_ = loc_958_;
				loc_967_ = loc_960_;
				if rt_equal_i32(loc_968_, 0) then
					loc_967_, loc_968_ = loc_968_, loc_967_;
				else
					loc_967_, loc_968_ = loc_968_, loc_967_;
					rt_memory_copy(loc_964_, loc_963_, loc_964_, loc_968_, loc_967_)
				end
			end
			return loc_963_, loc_962_
		end), "i32->i32")
	end)(module_locals[91], module_locals[106], module_locals[3]);
	module_locals[91][1] = (function(loc_969_)
		return rt_function_type((function(loc_970_, loc_971_)
			local loc_972_, loc_973_, loc_974_, loc_975_, loc_976_, loc_977_
			if rt_equal_i32(rt_and_i32(loc_970_, 3), 0) then
				loc_972_ = loc_971_;
				loc_973_ = loc_970_;
				loc_974_ = loc_969_;
				loc_975_ = loc_970_;
				loc_977_ = 0;
			else
				loc_972_ = loc_971_;
				loc_973_ = loc_970_;
				loc_974_ = loc_969_;
				loc_975_ = loc_970_;
				loc_977_ = rt_load_i32_from_u8(loc_974_, loc_973_, 0);
				if rt_not_equal_i32(loc_977_, 0) then
					loc_977_ = loc_975_;
					loc_975_ = bit32_or(loc_973_ + 1, 0);
					if rt_equal_i32(rt_and_i32(loc_975_, 3), 0) then
						loc_977_ = 0;
					else
						loc_977_ = rt_load_i32_from_u8(loc_974_, loc_975_, 0);
						if rt_equal_i32(loc_977_, 0) then
							loc_977_ = 1;
						else
							loc_977_ = loc_975_;
							loc_975_ = bit32_or(loc_973_ + 2, 0);
							if rt_equal_i32(rt_and_i32(loc_975_, 3), 0) then
								loc_977_ = 0;
							else
								loc_977_ = rt_load_i32_from_u8(loc_974_, loc_975_, 0);
								if rt_equal_i32(loc_977_, 0) then
									loc_977_ = 1;
								else
									loc_977_ = loc_975_;
									loc_975_ = bit32_or(loc_973_ + 3, 0);
									if rt_equal_i32(rt_and_i32(loc_975_, 3), 0) then
										loc_977_ = 0;
									else
										loc_977_ = rt_load_i32_from_u8(loc_974_, loc_975_, 0);
										if rt_equal_i32(loc_977_, 0) then
											loc_977_ = 1;
										else
											loc_977_ = loc_975_;
											loc_975_ = bit32_or(loc_973_ + 4, 0);
											if rt_not_equal_i32(rt_and_i32(loc_975_, 3), 0) then
												loc_977_ = 1;
											else
												loc_977_ = 0;
											end
										end
									end
								end
							end
						end
					end
				else
					loc_976_ = loc_975_;
					loc_977_ = 2;
					loc_973_ = bit32_or(loc_973_ - loc_973_, 0);
					loc_975_ = loc_976_;
				end
			end
			if (loc_977_) >= 0 and (loc_977_) < 2 then
				if (loc_977_) < 1 then
					loc_977_ = loc_975_;
					loc_975_ = bit32_or(loc_977_ + -5, 0);
					loc_976_ = bit32_or(loc_977_ + -4, 0);
					repeat
						rt_yield_budget = rt_yield_budget - 1
						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
						loc_976_ = bit32_or(loc_976_ + 4, 0);
						loc_977_ = buffer_read_i32(loc_974_[1], loc_976_, 0);
						loc_975_ = bit32_or(loc_975_ + 4, 0);
					until not (rt_equal_i32(rt_and_i32(rt_or_i32(bit32_or(16843008 - loc_977_, 0), loc_977_), -2139062144), -2139062144))
					repeat
						rt_yield_budget = rt_yield_budget - 1
						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
						loc_977_ = rt_load_i32_from_u8(loc_974_, loc_976_, 0);
						loc_975_ = bit32_or(loc_975_ + 1, 0);
						loc_976_ = bit32_or(loc_976_ + 1, 0);
					until loc_977_ == 0
					loc_976_ = 0;
				else
					loc_976_ = 0;
				end
			else
				loc_976_ = 1;
			end
			if not (rt_not_equal_i32(loc_976_, 0)) then
				loc_973_ = bit32_or(loc_975_ - loc_973_, 0);
			end
			return loc_973_, loc_972_
		end), "i32->i32")
	end)(module_locals[3]);
	module_locals[92] = { nil };
	module_locals[92][1] = rt_function_type((function(loc_978_, loc_979_, loc_980_)
		local loc_981_
		loc_981_ = loc_980_;
		return loc_978_, loc_981_
	end), "i32,i32->i32");
	module_locals[93] = { nil };
	module_locals[93][1] = (function(loc_982_)
		return rt_function_type((function(loc_983_, loc_984_, loc_985_)
			local loc_986_, loc_987_
			loc_987_ = loc_985_;
			loc_987_ = loc_982_[1](loc_983_, loc_984_, loc_987_)
			return loc_987_, loc_986_
		end), "i32,i32->i32")
	end)(module_locals[92]);
	module_locals[94] = { nil };
	module_locals[94][1] = (function(loc_988_, loc_989_)
		return rt_function_type((function(loc_990_, loc_991_)
			local loc_992_, loc_993_, loc_994_, loc_995_, loc_996_, loc_997_
			loc_992_ = buffer_read_i32(loc_989_[1], 0, 71952);
			loc_994_ = loc_989_;
			if rt_not_equal_i32(loc_992_, 0) then
				loc_993_ = loc_991_;
				loc_996_ = loc_988_;
				loc_997_ = loc_990_;
			else
				loc_993_ = loc_991_;
				loc_995_ = loc_992_;
				loc_996_ = loc_988_;
				loc_997_ = loc_990_;
				rt_store_i32(loc_994_, 0, 71952, 71928)
				loc_992_ = 71928;
			end
			loc_995_ = 0;
			if not (rt_greater_than_u32(loc_997_, 76)) then
				loc_995_ = loc_997_;
			end
			loc_995_ = rt_load_i32_from_u16(loc_994_, rt_shift_left_i32(loc_995_, 1), 5824);
			loc_992_ = buffer_read_i32(loc_994_[1], loc_992_, 20);
			loc_993_ = loc_996_[1](bit32_or(loc_995_ + 4272, 0), loc_992_, loc_993_)
			return loc_993_, loc_992_
		end), "i32->i32")
	end)(module_locals[93], module_locals[3]);
	module_locals[95] = { nil };
	module_locals[95][1] = (function(loc_998_)
		return rt_function_type((function(loc_999_, loc_1000_, loc_1001_)
			local loc_1002_, loc_1003_, loc_1004_, loc_1005_
			loc_1005_ = loc_1001_;
			loc_1005_ = loc_998_[1](loc_999_, 0, loc_1000_, loc_1005_)
			loc_1003_ = bit32_or(loc_1005_ - loc_999_, 0);
			if rt_not_equal_i32(loc_1005_, 0) then
				loc_1004_ = loc_998_;
				loc_1005_ = loc_1000_;
			else
				loc_1004_ = loc_998_;
				loc_1005_ = loc_1000_;
				loc_1003_ = loc_1005_;
			end
			return loc_1003_, loc_1002_
		end), "i32,i32->i32")
	end)(module_locals[85]);
	module_locals[96] = { nil };
	module_locals[96][1] = (function(loc_1006_)
		return rt_function_type((function(loc_1007_, loc_1008_, loc_1009_, loc_1010_)
			local loc_1011_, loc_1012_, loc_1013_, loc_1014_, loc_1015_, loc_1016_
			loc_1014_ = 1;
			if rt_equal_i32(loc_1007_, 0) then
				loc_1011_ = loc_1010_;
				loc_1012_ = loc_1007_;
				loc_1013_ = loc_1006_;
				loc_1015_ = loc_1008_;
				loc_1015_ = 0;
			else
				loc_1011_ = loc_1010_;
				loc_1012_ = loc_1007_;
				loc_1013_ = loc_1006_;
				loc_1015_ = loc_1008_;
				if rt_greater_than_u32(loc_1015_, 127) then
					loc_1016_ = loc_1014_;
					loc_1014_ = buffer_read_i32(loc_1013_[1], 0, 71952);
					if not (rt_not_equal_i32(loc_1014_, 0)) then
						loc_1016_ = loc_1014_;
						rt_store_i32(loc_1013_, 0, 71952, 71928)
						loc_1014_ = 71928;
					end
					loc_1016_ = buffer_read_i32(loc_1013_[1], loc_1014_, 0);
					if rt_not_equal_i32(loc_1016_, 0) then
						if rt_greater_than_u32(loc_1015_, 2047) then
							if rt_less_than_u32(loc_1015_, 55296) then
								loc_1016_ = 0;
							else
								if rt_not_equal_i32(rt_and_i32(loc_1015_, -8192), 57344) then
									if rt_greater_than_u32(bit32_or(loc_1015_ + -65536, 0), 1048575) then
										rt_store_i32(loc_1013_, 0, 70852, 25)
										loc_1016_ = 1;
									else
										rt_store_i32_into_i8(loc_1013_, loc_1012_, 3, rt_or_i32(rt_and_i32(loc_1015_, 63), 128))
										rt_store_i32_into_i8(loc_1013_, loc_1012_, 0, rt_or_i32(rt_shift_right_u32(loc_1015_, 18), 240))
										rt_store_i32_into_i8(loc_1013_, loc_1012_, 2, rt_or_i32(rt_and_i32(rt_shift_right_u32(loc_1015_, 6), 63), 128))
										rt_store_i32_into_i8(loc_1013_, loc_1012_, 1, rt_or_i32(rt_and_i32(rt_shift_right_u32(loc_1015_, 12), 63), 128))
										loc_1016_ = 2;
										loc_1012_ = 4;
									end
								else
									loc_1016_ = 0;
								end
							end
							if (loc_1016_) >= 0 and (loc_1016_) < 2 then
								if (loc_1016_) < 1 then
									rt_store_i32_into_i8(loc_1013_, loc_1012_, 2, rt_or_i32(rt_and_i32(loc_1015_, 63), 128))
									rt_store_i32_into_i8(loc_1013_, loc_1012_, 0, rt_or_i32(rt_shift_right_u32(loc_1015_, 12), 224))
									rt_store_i32_into_i8(loc_1013_, loc_1012_, 1, rt_or_i32(rt_and_i32(rt_shift_right_u32(loc_1015_, 6), 63), 128))
									loc_1015_ = 3;
									loc_1012_ = 3;
								else
									loc_1015_ = 0;
								end
							else
								loc_1015_ = 4;
							end
						else
							rt_store_i32_into_i8(loc_1013_, loc_1012_, 1, rt_or_i32(rt_and_i32(loc_1015_, 63), 128))
							rt_store_i32_into_i8(loc_1013_, loc_1012_, 0, rt_or_i32(rt_shift_right_u32(loc_1015_, 6), 192))
							loc_1015_ = 2;
							loc_1012_ = 2;
						end
					else
						if rt_equal_i32(rt_and_i32(loc_1015_, -128), 57216) then
							loc_1016_ = loc_1015_;
							loc_1015_ = loc_1012_;
							rt_store_i32_into_i8(loc_1013_, loc_1015_, 0, loc_1016_)
							loc_1015_ = 1;
							loc_1012_ = 1;
						else
							loc_1016_ = loc_1012_;
							rt_store_i32(loc_1013_, 0, 70852, 25)
							loc_1015_ = 0;
							loc_1012_ = loc_1016_;
						end
					end
					if (loc_1015_) >= 0 and (loc_1015_) < 4 then
						if (loc_1015_) < 2 then
							if (loc_1015_) < 1 then
								loc_1015_ = loc_1014_;
								loc_1015_ = 0;
								loc_1014_ = -1;
							else
								loc_1015_ = 1;
							end
						elseif (loc_1015_) > 2 then
							loc_1015_ = 1;
						else
							loc_1015_ = 1;
						end
					else
						loc_1015_ = 1;
					end
				else
					loc_1016_ = loc_1014_;
					rt_store_i32_into_i8(loc_1013_, loc_1012_, 0, loc_1015_)
					loc_1015_ = 1;
					loc_1012_ = 1;
					loc_1014_ = loc_1016_;
				end
			end
			if not (rt_not_equal_i32(loc_1015_, 0)) then
				loc_1012_ = loc_1014_;
			end
			return loc_1012_, loc_1011_
		end), "i32,i32,i32->i32")
	end)(module_locals[3]);
	module_locals[97] = { nil };
	module_locals[97][1] = (function(loc_1017_)
		return rt_function_type((function(loc_1018_, loc_1019_, loc_1020_)
			local loc_1021_, loc_1022_, loc_1023_, loc_1024_, loc_1025_
			if rt_not_equal_i32(loc_1018_, 0) then
				loc_1021_ = loc_1019_;
				loc_1022_ = loc_1020_;
				loc_1024_ = loc_1018_;
				loc_1025_ = loc_1017_;
				loc_1023_ = loc_1025_;
				loc_1022_ = loc_1025_[1](loc_1024_, loc_1021_, 0, loc_1022_)
			else
				loc_1022_ = loc_1019_;
				loc_1023_ = loc_1018_;
				loc_1024_ = loc_1017_;
				loc_1025_ = loc_1020_;
				loc_1023_ = loc_1024_;
				loc_1022_ = 0;
				loc_1021_ = loc_1025_;
			end
			return loc_1022_, loc_1021_
		end), "i32,i32->i32")
	end)(module_locals[96]);
	module_locals[98] = { nil };
	module_locals[98][1] = (function(loc_1026_, loc_1027_)
		return rt_function_type((function(loc_1028_, loc_1029_, loc_1030_)
			local loc_1031_, loc_1032_, loc_1033_, loc_1034_, loc_1035_, loc_1036_, loc_1037_
			loc_1036_ = rt_transmute_f64_to_i64(loc_1028_);
			loc_1037_ = rt_and_i32(rt_narrow_i64(rt_shift_right_u64(loc_1036_, into_bits_i64(52, 0))), 2047);
			if rt_equal_i32(loc_1037_, 2047) then
				loc_1031_ = loc_1030_;
				loc_1032_ = loc_1028_;
				loc_1033_ = loc_1027_;
				loc_1034_ = loc_1026_;
				loc_1035_ = loc_1029_;
				loc_1035_ = 0;
			else
				loc_1031_ = loc_1030_;
				loc_1032_ = loc_1028_;
				loc_1033_ = loc_1027_;
				loc_1034_ = loc_1026_;
				loc_1035_ = loc_1029_;
				if rt_not_equal_i32(loc_1037_, 0) then
					loc_1036_, loc_1037_ = loc_1037_, loc_1036_;
					rt_store_i32(loc_1033_, loc_1035_, 0, bit32_or(loc_1036_ + -1022, 0))
					loc_1035_ = 0;
					loc_1032_ = rt_transmute_i64_to_f64(rt_or_i64(rt_and_i64(loc_1037_, into_bits_i64(4294967295, 2148532223)), into_bits_i64(0, 1071644672)));
				else
					loc_1036_, loc_1037_ = loc_1037_, loc_1036_;
					if rt_not_equal_f64(loc_1032_, from_bits_f64(0, 0) --[[ 0_f64 ]]) then
						loc_1036_ = loc_1035_;
						loc_1035_ = loc_1032_;
						loc_1032_ = loc_1034_;
						loc_1037_ = loc_1031_;
						loc_1034_ = loc_1032_;
						loc_1032_ = loc_1032_[1](rt_multiply_f64(loc_1035_, from_bits_f64(0, 1139802112) --[[ 18446744073709552000_f64 ]]), loc_1036_, loc_1037_)
						loc_1037_ = buffer_read_i32(loc_1033_[1], loc_1036_, 0);
						rt_store_i32(loc_1033_, loc_1036_, 0, bit32_or(loc_1037_ + -64, 0))
						loc_1035_ = 1;
					else
						loc_1036_ = loc_1032_;
						loc_1032_ = loc_1034_;
						loc_1037_ = loc_1031_;
						loc_1034_ = loc_1032_;
						rt_store_i32(loc_1033_, loc_1035_, 0, 0)
						loc_1035_ = 1;
						loc_1032_ = loc_1036_;
						loc_1031_ = loc_1037_;
					end
				end
			end
			if rt_not_equal_i32(loc_1035_, 0) then
			end
			return loc_1032_, loc_1031_
		end), "f64,i32->f64")
	end)(module_locals[98], module_locals[3]);
	module_locals[99] = { nil };
	module_locals[99][1] = rt_function_type((function(loc_1038_)
		local loc_1039_, loc_1040_
		loc_1039_ = loc_1038_;
		loc_1040_ = error('unreachable code');
		return loc_1039_
	end), "->");
	module_locals[101] = { nil };
	module_locals[100][1] = (function(loc_1041_, loc_1042_, loc_1043_, loc_1044_, loc_1045_)
		return rt_function_type((function(loc_1046_, loc_1047_, loc_1048_, loc_1049_)
			local loc_1050_, loc_1051_, loc_1052_, loc_1053_, loc_1054_, loc_1055_, loc_1056_, loc_1057_, loc_1058_, loc_1059_, loc_1060_, loc_1061_, loc_1062_
			loc_1062_ = loc_1043_[1];
			loc_1052_ = loc_1043_;
			loc_1055_ = bit32_or(loc_1062_ - 208, 0);
			loc_1052_[1] = loc_1055_;
			rt_store_i32(loc_1045_, loc_1055_, 204, loc_1048_)
			loc_1054_ = loc_1045_;
			rt_store_i64(loc_1054_, bit32_or(bit32_or(loc_1055_ + 160, 0) + 32, 0), 0, into_bits_i64(0, 0))
			rt_store_i64(loc_1054_, bit32_or(loc_1055_ + 184, 0), 0, into_bits_i64(0, 0))
			rt_store_i64(loc_1054_, bit32_or(loc_1055_ + 176, 0), 0, into_bits_i64(0, 0))
			rt_store_i64(loc_1054_, loc_1055_, 168, into_bits_i64(0, 0))
			rt_store_i64(loc_1054_, loc_1055_, 160, into_bits_i64(0, 0))
			rt_store_i32(loc_1054_, loc_1055_, 200, loc_1048_)
			loc_1053_ = loc_1044_;
			loc_1062_ = loc_1049_;
			loc_1062_ = loc_1042_[1](0, loc_1047_, bit32_or(loc_1055_ + 200, 0), bit32_or(loc_1055_ + 80, 0), bit32_or(loc_1055_ + 160, 0), loc_1062_)
			if rt_greater_than_equal_s32(loc_1062_, 0) then
				loc_1051_ = loc_1047_;
				loc_1056_ = loc_1041_;
				loc_1057_ = loc_1042_;
				loc_1058_ = loc_1048_;
				loc_1060_ = loc_1046_;
				loc_1061_ = buffer_read_i32(loc_1054_[1], loc_1060_, 0);
				rt_store_i32(loc_1054_, loc_1060_, 0, rt_and_i32(loc_1061_, -33))
				loc_1062_ = buffer_read_i32(loc_1054_[1], loc_1060_, 44);
				if rt_not_equal_i32(loc_1062_, 0) then
					loc_1062_ = buffer_read_i32(loc_1054_[1], loc_1060_, 16);
					loc_1059_ = 0;
					if rt_not_equal_i32(loc_1062_, 0) then
						loc_1062_ = 1;
					else
						loc_1062_ = 0;
					end
				else
					rt_store_i32(loc_1054_, loc_1060_, 44, 80)
					rt_store_i32(loc_1054_, loc_1060_, 24, 0)
					rt_store_i64(loc_1054_, loc_1060_, 16, into_bits_i64(0, 0))
					loc_1059_ = buffer_read_i32(loc_1054_[1], loc_1060_, 40);
					rt_store_i32(loc_1054_, loc_1060_, 40, loc_1055_)
					loc_1062_ = 0;
				end
				if rt_not_equal_i32(loc_1062_, 0) then
					loc_1062_ = 0;
				else
					loc_1062_ = loc_1058_;
					loc_1062_ = loc_1050_;
					loc_1062_ = loc_1056_[1](loc_1060_, loc_1062_)
					loc_1058_ = -1;
					if rt_not_equal_i32(loc_1062_, 0) then
						loc_1062_ = 1;
					else
						loc_1062_ = 0;
					end
				end
				if not (rt_not_equal_i32(loc_1062_, 0)) then
					loc_1050_, loc_1057_ = loc_1057_, loc_1050_;
					loc_1057_, loc_1058_ = loc_1058_, loc_1057_;
					loc_1057_ = loc_1050_;
					loc_1058_ = loc_1050_[1](loc_1060_, loc_1051_, bit32_or(loc_1055_ + 200, 0), bit32_or(loc_1055_ + 80, 0), bit32_or(loc_1055_ + 160, 0), loc_1058_)
				end
				loc_1051_ = rt_and_i32(loc_1061_, 32);
				if not (rt_equal_i32(loc_1059_, 0)) then
					loc_1061_ = loc_1050_;
					loc_1050_ = buffer_read_i32(loc_1054_[1], loc_1060_, 32);
					loc_1050_ = rt_table_get_function(loc_1053_, loc_1050_, "i32,i32,i32->i32");
					loc_1061_ = loc_1050_(loc_1060_, 0, 0, loc_1061_)
					rt_store_i32(loc_1054_, loc_1060_, 44, 0)
					rt_store_i32(loc_1054_, loc_1060_, 40, loc_1059_)
					rt_store_i32(loc_1054_, loc_1060_, 24, 0)
					loc_1061_ = buffer_read_i32(loc_1054_[1], loc_1060_, 20);
					rt_store_i64(loc_1054_, loc_1060_, 16, into_bits_i64(0, 0))
					loc_1059_ = -1;
					if not (rt_not_equal_i32(loc_1061_, 0)) then
						loc_1058_ = loc_1059_;
					end
				end
				loc_1059_ = buffer_read_i32(loc_1054_[1], loc_1060_, 0);
				rt_store_i32(loc_1054_, loc_1060_, 0, rt_or_i32(loc_1059_, loc_1051_))
				loc_1051_ = -1;
				if not (rt_not_equal_i32(rt_and_i32(loc_1059_, 32), 0)) then
					loc_1051_ = loc_1058_;
				end
			else
				loc_1056_ = loc_1041_;
				loc_1057_ = loc_1042_;
				loc_1060_ = loc_1048_;
				loc_1061_ = loc_1047_;
				loc_1062_ = loc_1046_;
				loc_1051_ = -1;
			end
			loc_1052_[1] = bit32_or(loc_1055_ + 208, 0);
			return loc_1051_, loc_1050_
		end), "i32,i32,i32->i32")
	end)(module_locals[78], module_locals[101], module_locals[114], module_locals[112], module_locals[3]);
	module_locals[102] = { nil };
	module_locals[103] = { nil };
	module_locals[101][1] = (function(loc_1063_, loc_1064_, loc_1065_, loc_1066_, loc_1067_, loc_1068_, loc_1069_, loc_1070_, loc_1071_)
		local __spider_scoped_dependencies = { loc_1063_, loc_1064_, loc_1065_, loc_1066_, loc_1067_, loc_1068_, loc_1069_, loc_1070_, loc_1071_ }
		return rt_function_type((function(loc_1072_, loc_1073_, loc_1074_, loc_1075_, loc_1076_, loc_1077_)
			local rt_add_i64, rt_convert_s32_to_f64, rt_convert_u32_to_f64, rt_divide_s32, rt_extend_s8_to_i32, rt_greater_than_equal_u64, rt_less_than_f64, rt_less_than_u64 = runtime.rt_add_i64, runtime.rt_convert_s32_to_f64, runtime.rt_convert_u32_to_f64, runtime.rt_divide_s32, runtime.rt_extend_s8_to_i32, runtime.rt_greater_than_equal_u64, runtime.rt_less_than_f64, runtime.rt_less_than_u64
			local loc_1078_, loc_1079_, loc_1080_, loc_1081_, loc_1082_, loc_1083_, loc_1084_, loc_1085_, loc_1086_, loc_1087_, loc_1088_, loc_1089_, loc_1090_, loc_1091_, loc_1092_, loc_1093_, loc_1094_, loc_1095_, loc_1096_, loc_1097_, loc_1098_, loc_1099_, loc_1100_, loc_1101_, loc_1102_, loc_1103_, loc_1104_, loc_1105_, loc_1106_, loc_1107_, loc_1108_, loc_1109_, loc_1110_, loc_1111_, loc_1112_, loc_1113_, loc_1114_, loc_1115_, loc_1116_, loc_1117_, loc_1118_, loc_1119_, loc_1120_, loc_1121_, loc_1122_, loc_1123_, loc_1124_, loc_1125_, loc_1126_, loc_1127_, loc_1128_, loc_1129_, loc_1130_, loc_1131_, loc_1132_
			loc_1132_ = __spider_scoped_dependencies[8][1];
			loc_1080_ = __spider_scoped_dependencies[8];
			loc_1132_ = bit32_or(loc_1132_ - 864, 0);
			loc_1080_[1] = loc_1132_;
			loc_1081_ = __spider_scoped_dependencies[9];
			loc_1096_ = 0;
			loc_1090_ = 0;
			loc_1091_ = loc_1072_;
			loc_1097_ = loc_1073_;
			loc_1092_ = loc_1074_;
			loc_1093_ = loc_1075_;
			loc_1094_ = loc_1076_;
			loc_1082_ = loc_1132_;
			loc_1098_ = bit32_or(bit32_or(loc_1132_ + 52, 0) + 12, 0);
			loc_1099_ = bit32_or(bit32_or(loc_1132_ + 96, 0) + -4, 0);
			loc_1100_ = bit32_or(bit32_or(loc_1132_ + 16, 0) + 25, 0);
			loc_1101_ = bit32_or(loc_1132_ + 39, 0);
			loc_1102_ = bit32_or(bit32_or(loc_1132_ + 52, 0) + 11, 0);
			loc_1103_ = bit32_or(bit32_or(loc_1132_ + 64, 0) + -1, 0);
			loc_1104_ = rt_or_i32(bit32_or(loc_1132_ + 64, 0), 8);
			loc_1105_ = rt_or_i32(bit32_or(loc_1132_ + 64, 0), 9);
			loc_1106_ = bit32_or(bit32_or(loc_1132_ + 52, 0) + 10, 0);
			loc_1107_ = bit32_or(loc_1132_ + 40, 0);
			loc_1095_ = 0;
			loc_1079_ = 0;
			loc_1108_ = 0;
			loc_1109_ = 0;
			loc_1110_ = 0;
			loc_1111_ = 0;
			loc_1112_ = into_bits_i64(0, 0);
			loc_1113_ = into_bits_i64(0, 0);
			loc_1078_ = loc_1077_;
			repeat
				rt_yield_budget = rt_yield_budget - 1
				if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
				loc_1132_ = loc_1090_;
				loc_1090_ = loc_1096_;
				loc_1096_ = loc_1132_;
				loc_1114_ = 0;
				repeat
					rt_yield_budget = rt_yield_budget - 1
					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
					if rt_greater_than_s32(loc_1114_, rt_exclusive_or_i32(loc_1079_, 2147483647)) then
						loc_1115_ = loc_1090_;
						loc_1090_ = loc_1097_;
						loc_1115_ = 0;
						loc_1096_ = 10;
					else
						loc_1115_ = loc_1090_;
						loc_1090_ = loc_1097_;
						loc_1132_ = loc_1114_;
						loc_1114_ = rt_load_i32_from_u8(loc_1081_, loc_1090_, 0);
						loc_1079_ = bit32_or(loc_1132_ + loc_1079_, 0);
						if rt_equal_i32(loc_1114_, 0) then
							loc_1115_ = 0;
							loc_1096_ = 4;
						else
							loc_1132_ = loc_1097_;
							loc_1132_ = loc_1090_;
							loc_1131_ = loc_1114_;
							repeat
								rt_yield_budget = rt_yield_budget - 1
								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
								loc_1129_ = loc_1096_;
								loc_1130_ = loc_1115_;
								loc_1131_ = rt_and_i32(loc_1131_, 255);
								if rt_equal_i32(loc_1131_, 0) then
									loc_1130_ = 0;
									loc_1096_ = 1;
								else
									if rt_not_equal_i32(loc_1131_, 37) then
										loc_1132_ = bit32_or(loc_1132_ + 1, 0);
										loc_1131_ = rt_load_i32_from_u8(loc_1081_, loc_1132_, 0);
										loc_1130_ = 1;
										loc_1096_ = 65535;
									else
										loc_1130_ = 0;
										loc_1096_ = 0;
									end
								end
								loc_1115_ = loc_1130_;
							until loc_1130_ == 0
							if rt_not_equal_i32(loc_1096_, 0) then
								loc_1097_ = loc_1132_;
							else
								loc_1097_ = loc_1132_;
								repeat
									rt_yield_budget = rt_yield_budget - 1
									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
									loc_1130_ = loc_1096_;
									loc_1131_ = loc_1115_;
									loc_1131_ = rt_load_i32_from_u8(loc_1081_, bit32_or(loc_1097_ + 1, 0), 0);
									if rt_not_equal_i32(loc_1131_, 37) then
										loc_1131_ = 0;
										loc_1096_ = 1;
									else
										loc_1097_ = bit32_or(loc_1097_ + 2, 0);
										loc_1131_ = rt_load_i32_from_u8(loc_1081_, loc_1097_, 0);
										loc_1132_ = bit32_or(loc_1132_ + 1, 0);
										if rt_equal_i32(loc_1131_, 37) then
											loc_1131_ = 1;
											loc_1096_ = 65535;
										else
											loc_1131_ = 0;
											loc_1096_ = 0;
										end
									end
									loc_1115_ = loc_1131_;
								until loc_1131_ == 0
								if rt_not_equal_i32(loc_1096_, 0) then
								end
							end
							loc_1114_ = bit32_or(loc_1132_ - loc_1090_, 0);
							loc_1116_ = rt_exclusive_or_i32(loc_1079_, 2147483647);
							if rt_greater_than_s32(loc_1114_, loc_1116_) then
								loc_1115_ = 0;
								loc_1096_ = 11;
							else
								if rt_equal_i32(loc_1091_, 0) then
									loc_1090_, loc_1116_ = loc_1116_, loc_1090_;
									loc_1116_, loc_1115_ = loc_1115_, loc_1116_;
									loc_1115_, loc_1096_ = loc_1096_, loc_1115_;
								else
									loc_1090_, loc_1116_ = loc_1116_, loc_1090_;
									loc_1116_, loc_1115_ = loc_1115_, loc_1116_;
									loc_1115_, loc_1096_ = loc_1096_, loc_1115_;
									loc_1132_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
									if not (rt_not_equal_i32(rt_and_i32(loc_1132_, 32), 0)) then
										loc_1131_ = __spider_scoped_dependencies[1];
										__spider_scoped_dependencies[1] = loc_1131_;
										loc_1132_ = loc_1078_;
										loc_1132_ = loc_1131_[1](loc_1096_, loc_1114_, loc_1091_, loc_1132_)
									end
								end
								if rt_not_equal_i32(loc_1114_, 0) then
									loc_1115_ = 1;
									loc_1096_ = 65535;
								else
									loc_1131_ = loc_1108_;
									loc_1132_ = loc_1114_;
									loc_1118_ = rt_load_i32_from_s8(loc_1081_, loc_1097_, 1);
									loc_1129_ = bit32_or(loc_1118_ + -48, 0);
									loc_1132_ = bit32_or(loc_1097_ + 1, 0);
									loc_1108_ = -1;
									if rt_greater_than_u32(loc_1129_, 9) then
										loc_1130_ = loc_1097_;
										loc_1131_ = loc_1109_;
										loc_1096_, loc_1115_ = loc_1115_, loc_1096_;
										loc_1115_, loc_1116_ = loc_1116_, loc_1115_;
									else
										loc_1130_ = loc_1097_;
										loc_1131_ = loc_1109_;
										loc_1096_, loc_1115_ = loc_1115_, loc_1096_;
										loc_1115_, loc_1116_ = loc_1116_, loc_1115_;
										loc_1128_ = rt_load_i32_from_u8(loc_1081_, loc_1130_, 2);
										if not (rt_not_equal_i32(loc_1128_, 36)) then
											loc_1126_ = loc_1118_;
											loc_1127_ = loc_1108_;
											loc_1128_ = loc_1132_;
											loc_1132_ = loc_1130_;
											loc_1130_ = loc_1129_;
											loc_1129_ = loc_1095_;
											loc_1118_ = rt_load_i32_from_s8(loc_1081_, loc_1132_, 3);
											loc_1095_ = 1;
											loc_1129_ = loc_1130_;
											loc_1132_ = bit32_or(loc_1132_ + 3, 0);
											loc_1108_ = loc_1130_;
										end
									end
									loc_1097_ = bit32_or(loc_1118_ + -32, 0);
									loc_1130_ = 0;
									if rt_less_than_equal_u32(loc_1097_, 31) then
										loc_1114_ = rt_shift_left_i32(1, loc_1097_);
										if rt_not_equal_i32(rt_and_i32(loc_1114_, 75913), 0) then
											loc_1132_ = bit32_or(loc_1132_ + 1, 0);
											loc_1119_ = 0;
											repeat
												rt_yield_budget = rt_yield_budget - 1
												if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
												loc_1126_ = loc_1118_;
												loc_1127_ = loc_1097_;
												loc_1128_ = loc_1096_;
												loc_1129_ = loc_1115_;
												loc_1130_ = loc_1114_;
												loc_1118_ = rt_load_i32_from_s8(loc_1081_, loc_1132_, 0);
												loc_1114_ = bit32_or(loc_1118_ + -32, 0);
												loc_1119_ = rt_or_i32(loc_1130_, loc_1119_);
												if rt_greater_than_equal_u32(loc_1114_, 32) then
													loc_1097_ = loc_1132_;
													loc_1130_ = 0;
													loc_1096_ = 1;
												else
													loc_1097_ = loc_1132_;
													loc_1114_ = rt_shift_left_i32(1, loc_1114_);
													loc_1132_ = bit32_or(loc_1097_ + 1, 0);
													if rt_not_equal_i32(rt_and_i32(loc_1114_, 75913), 0) then
														loc_1130_ = 1;
														loc_1096_ = 65535;
													else
														loc_1130_ = 0;
														loc_1096_ = 0;
													end
												end
												loc_1115_ = loc_1130_;
											until loc_1130_ == 0
											if rt_not_equal_i32(loc_1096_, 0) then
											end
										else
											loc_1129_ = loc_1097_;
											loc_1097_ = loc_1132_;
											loc_1119_ = loc_1130_;
										end
									else
										loc_1128_ = loc_1097_;
										loc_1097_ = loc_1132_;
										loc_1114_ = loc_1129_;
										loc_1119_ = loc_1130_;
									end
									if rt_not_equal_i32(loc_1118_, 42) then
										loc_1117_ = bit32_or(loc_1118_ + -48, 0);
										loc_1109_ = 0;
										if rt_greater_than_u32(loc_1117_, 9) then
											loc_1132_ = 0;
										else
											loc_1130_ = loc_1097_;
											loc_1132_ = loc_1114_;
											loc_1132_ = loc_1115_;
											loc_1131_ = loc_1096_;
											loc_1097_ = loc_1130_;
											loc_1114_ = loc_1130_;
											repeat
												rt_yield_budget = rt_yield_budget - 1
												if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
												loc_1130_ = loc_1097_;
												if rt_greater_than_u32(loc_1109_, 214748364) then
													loc_1130_ = loc_1109_;
													loc_1131_ = loc_1117_;
													loc_1132_ = loc_1114_;
													loc_1097_ = rt_load_i32_from_s8(loc_1081_, loc_1132_, 1);
													loc_1114_ = bit32_or(loc_1132_ + 1, 0);
													loc_1117_ = bit32_or(loc_1097_ + -48, 0);
													loc_1109_ = -1;
													if rt_less_than_u32(loc_1117_, 10) then
														loc_1130_ = 1;
														loc_1131_ = 65535;
													else
														loc_1130_ = 0;
														loc_1131_ = 1;
													end
												else
													loc_1129_ = loc_1118_;
													loc_1130_ = loc_1109_;
													loc_1131_ = loc_1117_;
													loc_1132_ = loc_1114_;
													loc_1130_ = rt_multiply_i32(loc_1130_, 10);
													loc_1118_ = (rt_greater_than_u32(loc_1131_, rt_exclusive_or_i32(loc_1130_, 2147483647)) and 1 or 0);
													loc_1109_ = -1;
													loc_1131_ = bit32_or(loc_1130_ + loc_1131_, 0);
													if rt_not_equal_i32(loc_1118_, 0) then
														loc_1131_, loc_1132_ = loc_1132_, loc_1131_;
													else
														loc_1130_ = loc_1109_;
														loc_1131_, loc_1132_ = loc_1132_, loc_1131_;
														loc_1109_ = loc_1132_;
													end
													loc_1132_ = rt_load_i32_from_s8(loc_1081_, loc_1131_, 1);
													loc_1114_ = bit32_or(loc_1131_ + 1, 0);
													loc_1117_ = bit32_or(loc_1132_ + -48, 0);
													if rt_less_than_u32(loc_1117_, 10) then
														loc_1097_ = loc_1114_;
														loc_1130_ = 1;
														loc_1131_ = 65535;
													else
														loc_1097_ = loc_1114_;
														loc_1130_ = 0;
														loc_1131_ = 0;
													end
												end
												loc_1132_ = loc_1130_;
											until loc_1130_ == 0
											if rt_not_equal_i32(loc_1131_, 0) then
												loc_1132_ = 1;
												loc_1115_ = 0;
												loc_1096_ = 1;
											else
												if rt_not_equal_i32(loc_1118_, 0) then
													loc_1132_ = 1;
													loc_1115_ = 0;
													loc_1096_ = 12;
												else
													loc_1130_ = loc_1132_;
													loc_1132_ = 0;
													loc_1115_ = loc_1130_;
													loc_1096_ = loc_1131_;
												end
											end
										end
									else
										loc_1130_ = loc_1114_;
										loc_1130_ = rt_load_i32_from_s8(loc_1081_, loc_1097_, 1);
										loc_1114_ = bit32_or(loc_1130_ + -48, 0);
										if rt_greater_than_u32(loc_1114_, 9) then
											loc_1109_ = loc_1131_;
											loc_1117_ = loc_1132_;
											loc_1132_ = 0;
										else
											loc_1109_ = loc_1131_;
											loc_1117_ = loc_1132_;
											loc_1132_ = rt_load_i32_from_u8(loc_1081_, loc_1097_, 2);
											if rt_not_equal_i32(loc_1132_, 36) then
												loc_1132_ = 0;
											else
												loc_1131_ = loc_1109_;
												loc_1132_ = loc_1095_;
												if rt_not_equal_i32(loc_1091_, 0) then
													loc_1131_ = loc_1097_;
													loc_1109_ = buffer_read_i32(loc_1081_[1], bit32_or(loc_1093_ + rt_shift_left_i32(loc_1114_, 3), 0), 0);
												else
													loc_1131_ = loc_1097_;
													rt_store_i32(loc_1081_, bit32_or(loc_1094_ + rt_shift_left_i32(loc_1114_, 2), 0), 0, 10)
													loc_1109_ = 0;
												end
												loc_1132_ = 1;
												loc_1097_ = bit32_or(loc_1131_ + 3, 0);
												loc_1095_ = 1;
											end
										end
										if rt_not_equal_i32(loc_1132_, 0) then
											loc_1132_ = 0;
										else
											if rt_not_equal_i32(loc_1095_, 0) then
												loc_1131_ = loc_1096_;
												loc_1132_ = loc_1115_;
												loc_1132_ = 1;
												loc_1115_ = 0;
												loc_1096_ = 5;
											else
												loc_1129_ = loc_1109_;
												loc_1130_ = loc_1095_;
												loc_1131_ = loc_1096_;
												loc_1132_ = loc_1115_;
												loc_1097_ = bit32_or(loc_1097_ + 1, 0);
												if rt_not_equal_i32(loc_1091_, 0) then
													loc_1096_ = loc_1131_;
													loc_1115_ = loc_1132_;
													loc_1132_ = loc_1114_;
													loc_1114_ = buffer_read_i32(loc_1081_[1], loc_1092_, 0);
													rt_store_i32(loc_1081_, loc_1092_, 0, bit32_or(loc_1114_ + 4, 0))
													loc_1109_ = buffer_read_i32(loc_1081_[1], loc_1114_, 0);
													loc_1132_ = 0;
													loc_1095_ = 0;
												else
													loc_1096_ = loc_1131_;
													loc_1115_ = loc_1132_;
													loc_1131_ = loc_1114_;
													loc_1132_ = 2;
													loc_1095_ = 0;
													loc_1114_ = loc_1131_;
													loc_1109_ = 0;
												end
											end
										end
										if (loc_1132_) >= 0 and (loc_1132_) < 2 then
											if (loc_1132_) < 1 then
												if rt_greater_than_s32(loc_1109_, -1) then
													loc_1132_ = 0;
												else
													loc_1132_ = 0;
													loc_1119_ = rt_or_i32(loc_1119_, 8192);
													loc_1109_ = bit32_or(0 - loc_1109_, 0);
												end
											else
												loc_1132_ = 1;
											end
										else
											loc_1132_ = 0;
										end
									end
									if not (rt_not_equal_i32(loc_1132_, 0)) then
										loc_1132_ = loc_1114_;
										loc_1132_ = rt_load_i32_from_u8(loc_1081_, loc_1097_, 0);
										loc_1114_ = 0;
										if rt_equal_i32(loc_1132_, 46) then
											loc_1131_ = loc_1117_;
											loc_1132_ = loc_1097_;
											loc_1090_, loc_1119_ = loc_1119_, loc_1090_;
											loc_1119_, loc_1116_ = loc_1116_, loc_1119_;
											loc_1116_, loc_1118_ = loc_1118_, loc_1116_;
											loc_1131_ = rt_load_i32_from_s8(loc_1081_, loc_1132_, 1);
											if rt_not_equal_i32(loc_1131_, 42) then
												loc_1097_ = bit32_or(loc_1132_ + 1, 0);
												loc_1132_ = bit32_or(loc_1131_ + -48, 0);
												if rt_less_than_equal_u32(loc_1132_, 9) then
													loc_1117_ = 0;
													repeat
														rt_yield_budget = rt_yield_budget - 1
														if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
														loc_1130_ = loc_1110_;
														loc_1131_ = loc_1116_;
														loc_1116_ = -1;
														if rt_greater_than_u32(loc_1117_, 214748364) then
															loc_1130_ = loc_1132_;
															loc_1131_ = loc_1117_;
															loc_1132_ = loc_1097_;
														else
															loc_1129_ = loc_1116_;
															loc_1130_ = loc_1132_;
															loc_1131_ = loc_1117_;
															loc_1132_ = loc_1097_;
															loc_1116_ = -1;
															loc_1129_ = rt_multiply_i32(loc_1131_, 10);
															loc_1131_ = bit32_or(loc_1129_ + loc_1130_, 0);
															if not (rt_greater_than_u32(loc_1130_, rt_exclusive_or_i32(loc_1129_, 2147483647))) then
																loc_1130_ = loc_1116_;
																loc_1116_ = loc_1131_;
															end
														end
														loc_1097_ = bit32_or(loc_1132_ + 1, 0);
														loc_1132_ = rt_load_i32_from_s8(loc_1081_, loc_1097_, 0);
														loc_1117_ = loc_1116_;
														loc_1110_ = 1;
														loc_1131_ = bit32_or(loc_1132_ + -48, 0);
														loc_1132_ = loc_1131_;
													until not (rt_less_than_u32(loc_1131_, 10))
													loc_1132_ = 0;
												else
													loc_1129_ = loc_1132_;
													loc_1130_ = loc_1110_;
													loc_1132_ = loc_1116_;
													loc_1132_ = 0;
													loc_1117_ = loc_1131_;
													loc_1116_ = 0;
													loc_1110_ = 1;
												end
											else
												loc_1131_ = rt_load_i32_from_s8(loc_1081_, loc_1132_, 2);
												loc_1117_ = bit32_or(loc_1131_ + -48, 0);
												if rt_greater_than_u32(loc_1117_, 9) then
													loc_1097_ = loc_1132_;
													loc_1132_ = 0;
												else
													loc_1097_ = loc_1132_;
													loc_1132_ = rt_load_i32_from_u8(loc_1081_, loc_1097_, 3);
													if rt_not_equal_i32(loc_1132_, 36) then
														loc_1132_ = 0;
													else
														loc_1131_ = loc_1110_;
														loc_1132_ = loc_1116_;
														if rt_not_equal_i32(loc_1091_, 0) then
															loc_1130_ = loc_1097_;
															loc_1131_ = buffer_read_i32(loc_1081_[1], bit32_or(loc_1093_ + rt_shift_left_i32(loc_1117_, 3), 0), 0);
															loc_1132_ = 2;
															loc_1097_ = bit32_or(loc_1130_ + 4, 0);
															loc_1116_ = loc_1131_;
															loc_1110_ = (rt_greater_than_s32(loc_1131_, -1) and 1 or 0);
														else
															loc_1130_ = loc_1097_;
															rt_store_i32(loc_1081_, bit32_or(loc_1094_ + rt_shift_left_i32(loc_1117_, 2), 0), 0, 10)
															loc_1132_ = 1;
															loc_1097_ = bit32_or(loc_1130_ + 4, 0);
															loc_1116_ = 0;
															loc_1110_ = (rt_greater_than_s32(0, -1) and 1 or 0);
														end
													end
												end
												if (loc_1132_) >= 0 and (loc_1132_) < 2 then
													if (loc_1132_) < 1 then
														if rt_not_equal_i32(loc_1095_, 0) then
															loc_1131_ = loc_1096_;
															loc_1132_ = loc_1115_;
															loc_1132_ = 1;
															loc_1115_ = 0;
															loc_1096_ = 6;
														else
															loc_1129_ = loc_1110_;
															loc_1130_ = loc_1116_;
															loc_1131_ = loc_1096_;
															loc_1132_ = loc_1115_;
															loc_1097_ = bit32_or(loc_1097_ + 2, 0);
															if rt_not_equal_i32(loc_1091_, 0) then
																loc_1096_ = loc_1131_;
																loc_1115_ = loc_1132_;
																loc_1132_ = loc_1117_;
																loc_1117_ = buffer_read_i32(loc_1081_[1], loc_1092_, 0);
																rt_store_i32(loc_1081_, loc_1092_, 0, bit32_or(loc_1117_ + 4, 0))
																loc_1131_ = buffer_read_i32(loc_1081_[1], loc_1117_, 0);
																loc_1132_ = 0;
																loc_1116_ = loc_1131_;
																loc_1110_ = (rt_greater_than_s32(loc_1131_, -1) and 1 or 0);
															else
																loc_1096_ = loc_1131_;
																loc_1115_ = loc_1132_;
																loc_1131_ = loc_1117_;
																loc_1132_ = 0;
																loc_1117_ = loc_1131_;
																loc_1116_ = 0;
																loc_1110_ = (rt_greater_than_s32(0, -1) and 1 or 0);
															end
														end
													else
														loc_1132_ = 0;
													end
												else
													loc_1132_ = 0;
												end
											end
										else
											loc_1129_ = loc_1110_;
											loc_1130_ = loc_1097_;
											loc_1131_ = loc_1117_;
											loc_1132_ = loc_1118_;
											loc_1118_ = loc_1090_;
											loc_1090_ = loc_1119_;
											loc_1119_ = loc_1116_;
											loc_1132_ = 0;
											loc_1097_ = loc_1130_;
											loc_1117_ = loc_1131_;
											loc_1116_ = -1;
											loc_1110_ = 0;
										end
										if not (rt_not_equal_i32(loc_1132_, 0)) then
											loc_1129_ = loc_1119_;
											loc_1130_ = loc_1118_;
											loc_1131_ = loc_1117_;
											loc_1132_ = loc_1116_;
											loc_1119_ = loc_1115_;
											loc_1118_ = loc_1096_;
											loc_1117_ = loc_1129_;
											loc_1116_ = loc_1130_;
											loc_1115_ = loc_1131_;
											loc_1096_ = loc_1132_;
											repeat
												rt_yield_budget = rt_yield_budget - 1
												if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
												loc_1129_ = loc_1115_;
												loc_1130_ = loc_1118_;
												loc_1131_ = loc_1119_;
												loc_1132_ = loc_1114_;
												loc_1114_ = rt_load_i32_from_s8(loc_1081_, loc_1097_, 0);
												if rt_less_than_u32(bit32_or(loc_1114_ + -123, 0), -58) then
													loc_1115_ = loc_1132_;
													loc_1132_ = 0;
													loc_1118_ = 1;
												else
													loc_1115_ = loc_1132_;
													loc_1114_ = rt_load_i32_from_u8(loc_1081_, bit32_or(bit32_or(loc_1114_ + rt_multiply_i32(loc_1115_, 58), 0) + 5919, 0), 0);
													loc_1097_ = bit32_or(loc_1097_ + 1, 0);
													if rt_less_than_u32(rt_and_i32(bit32_or(loc_1114_ + -1, 0), 255), 8) then
														loc_1132_ = 1;
														loc_1118_ = 65535;
													else
														loc_1132_ = 0;
														loc_1118_ = 0;
													end
												end
												loc_1119_ = loc_1132_;
											until loc_1132_ == 0
											if rt_not_equal_i32(loc_1118_, 0) then
												loc_1115_ = 0;
												loc_1096_ = 7;
											else
												if rt_equal_i32(loc_1114_, 27) then
													loc_1131_ = loc_1118_;
													loc_1118_ = loc_1116_;
													loc_1116_ = loc_1096_;
													loc_1132_ = loc_1119_;
													loc_1119_ = loc_1117_;
													loc_1117_ = loc_1115_;
													if rt_greater_than_s32(loc_1108_, -1) then
														loc_1132_ = 1;
														loc_1115_ = 0;
														loc_1096_ = 9;
													else
														loc_1130_ = loc_1114_;
														loc_1114_ = 0;
														if rt_equal_i32(loc_1091_, 0) then
															loc_1132_ = 1;
															loc_1115_ = 1;
															loc_1096_ = 65535;
														else
															loc_1130_ = loc_1132_;
															loc_1132_ = 0;
															loc_1115_ = loc_1130_;
															loc_1096_ = loc_1131_;
														end
													end
												else
													loc_1131_ = loc_1118_;
													loc_1118_ = loc_1116_;
													loc_1116_ = loc_1096_;
													loc_1132_ = loc_1119_;
													loc_1119_ = loc_1117_;
													loc_1117_ = loc_1115_;
													if rt_equal_i32(loc_1114_, 0) then
														loc_1132_ = 1;
														loc_1115_ = 0;
														loc_1096_ = 8;
													else
														if rt_less_than_s32(loc_1108_, 0) then
															loc_1096_ = loc_1131_;
															loc_1115_ = loc_1132_;
															loc_1131_ = __spider_scoped_dependencies[6];
															loc_1132_ = loc_1078_;
															if rt_not_equal_i32(loc_1091_, 0) then
																__spider_scoped_dependencies[6] = loc_1131_;
																loc_1131_[1](bit32_or(loc_1082_ + 40, 0), loc_1114_, loc_1092_, loc_1132_)
																loc_1132_ = 0;
															else
																loc_1129_ = loc_1096_;
																loc_1130_ = loc_1115_;
																loc_1131_, loc_1132_ = loc_1132_, loc_1131_;
																__spider_scoped_dependencies[6] = loc_1132_;
																loc_1132_ = 1;
																loc_1115_ = 0;
																loc_1096_ = 2;
																loc_1078_ = loc_1131_;
															end
														else
															loc_1096_ = loc_1131_;
															loc_1115_ = loc_1132_;
															loc_1131_ = __spider_scoped_dependencies[6];
															loc_1132_ = loc_1078_;
															if rt_not_equal_i32(loc_1091_, 0) then
																loc_1078_ = loc_1132_;
																__spider_scoped_dependencies[6] = loc_1131_;
																loc_1132_ = rt_load_i64(loc_1081_, bit32_or(loc_1093_ + rt_shift_left_i32(loc_1108_, 3), 0), 0);
																rt_store_i64(loc_1081_, loc_1082_, 40, loc_1132_)
																loc_1132_ = 0;
															else
																loc_1078_ = loc_1132_;
																__spider_scoped_dependencies[6] = loc_1131_;
																loc_1131_ = loc_1096_;
																loc_1132_ = loc_1115_;
																loc_1132_ = 1;
																loc_1115_ = 0;
																loc_1096_ = 0;
															end
														end
													end
												end
												if not (rt_not_equal_i32(loc_1132_, 0)) then
													loc_1132_ = loc_1108_;
													loc_1108_ = buffer_read_i32(loc_1081_[1], loc_1091_, 0);
													if rt_not_equal_i32(rt_and_i32(loc_1108_, 32), 0) then
														loc_1096_, loc_1116_ = loc_1116_, loc_1096_;
														loc_1116_, loc_1118_ = loc_1118_, loc_1116_;
														loc_1115_, loc_1117_ = loc_1117_, loc_1115_;
														loc_1117_, loc_1119_ = loc_1119_, loc_1117_;
														loc_1115_ = 0;
														loc_1096_ = 23;
													else
														loc_1132_ = loc_1114_;
														loc_1096_, loc_1116_ = loc_1116_, loc_1096_;
														loc_1116_, loc_1118_ = loc_1118_, loc_1116_;
														loc_1115_, loc_1117_ = loc_1117_, loc_1115_;
														loc_1117_, loc_1119_ = loc_1119_, loc_1117_;
														loc_1120_ = rt_and_i32(loc_1090_, -65537);
														if rt_not_equal_i32(rt_and_i32(loc_1090_, 8192), 0) then
															loc_1121_ = loc_1096_;
															loc_1096_ = loc_1118_;
															loc_1118_ = loc_1116_;
															loc_1116_ = loc_1120_;
															loc_1122_ = loc_1115_;
															loc_1115_ = loc_1119_;
															loc_1119_ = loc_1117_;
															loc_1132_ = loc_1090_;
														else
															loc_1121_ = loc_1096_;
															loc_1096_ = loc_1118_;
															loc_1118_ = loc_1116_;
															loc_1116_ = loc_1120_;
															loc_1122_ = loc_1115_;
															loc_1115_ = loc_1119_;
															loc_1119_ = loc_1117_;
															loc_1131_ = loc_1120_;
															loc_1132_ = loc_1090_;
															loc_1120_ = loc_1132_;
														end
														loc_1117_ = rt_load_i32_from_u8(loc_1081_, bit32_or(loc_1097_ + -1, 0), 0);
														loc_1131_ = rt_extend_s8_to_i32(loc_1117_);
														loc_1090_ = rt_and_i32(loc_1131_, -45);
														if rt_equal_i32(rt_and_i32(loc_1117_, 15), 3) then
															loc_1132_ = loc_1131_;
														else
															loc_1130_ = loc_1090_;
															loc_1132_ = loc_1131_;
															loc_1090_ = loc_1131_;
														end
														if rt_not_equal_i32(loc_1122_, 0) then
															loc_1114_ = loc_1132_;
														else
															loc_1114_ = loc_1132_;
															loc_1131_ = loc_1090_;
															loc_1090_ = loc_1132_;
														end
														loc_1132_ = bit32_or(loc_1090_ + -65, 0);
														if (loc_1132_) >= 0 and (loc_1132_) < 56 then
															if (loc_1132_) < 28 then
																if (loc_1132_) < 14 then
																	if (loc_1132_) < 7 then
																		if (loc_1132_) < 3 then
																			if (loc_1132_) < 1 then
																				loc_1132_ = 3;
																			elseif (loc_1132_) > 1 then
																				loc_1132_ = loc_1112_;
																				loc_1112_ = rt_load_i64(loc_1081_, loc_1082_, 40);
																				if rt_equal_i32((rt_equal_i64(loc_1112_, into_bits_i64(0, 0)) and 1 or 0), 0) then
																					loc_1130_ = loc_1121_;
																					loc_1131_ = loc_1082_;
																					loc_1132_ = loc_1122_;
																					rt_store_i32(loc_1081_, loc_1131_, 12, 0)
																					rt_store_i64_into_i32(loc_1081_, loc_1131_, 8, loc_1112_)
																					rt_store_i32(loc_1081_, loc_1131_, 40, bit32_or(loc_1131_ + 8, 0))
																					loc_1132_ = 0;
																					loc_1082_ = loc_1131_;
																					loc_1122_ = bit32_or(loc_1131_ + 8, 0);
																					loc_1121_ = -1;
																				else
																					loc_1129_ = loc_1082_;
																					loc_1130_ = loc_1121_;
																					loc_1131_ = loc_1122_;
																					loc_1132_ = loc_1114_;
																					loc_1132_ = 2;
																					loc_1082_ = loc_1129_;
																					loc_1114_ = 0;
																					loc_1122_ = loc_1131_;
																					loc_1121_ = loc_1130_;
																				end
																			else
																				loc_1132_ = 9;
																			end
																		elseif (loc_1132_) > 3 then
																			if (loc_1132_) < 5 then
																				loc_1132_ = 3;
																			elseif (loc_1132_) > 5 then
																				loc_1132_ = 3;
																			else
																				loc_1132_ = 3;
																			end
																		else
																			loc_1132_ = 9;
																		end
																	elseif (loc_1132_) > 7 then
																		if (loc_1132_) < 11 then
																			if (loc_1132_) < 9 then
																				loc_1132_ = 9;
																			elseif (loc_1132_) > 9 then
																				loc_1132_ = 9;
																			else
																				loc_1132_ = 9;
																			end
																		elseif (loc_1132_) > 11 then
																			if (loc_1132_) < 13 then
																				loc_1132_ = 9;
																			else
																				loc_1132_ = 9;
																			end
																		else
																			loc_1132_ = 9;
																		end
																	else
																		loc_1132_ = 9;
																	end
																elseif (loc_1132_) > 14 then
																	if (loc_1132_) < 21 then
																		if (loc_1132_) < 18 then
																			if (loc_1132_) < 16 then
																				loc_1132_ = 9;
																			elseif (loc_1132_) > 16 then
																				loc_1132_ = 9;
																			else
																				loc_1132_ = 9;
																			end
																		elseif (loc_1132_) > 18 then
																			if (loc_1132_) < 20 then
																				loc_1132_ = 9;
																			else
																				loc_1132_ = 9;
																			end
																		else
																			if rt_equal_i32(loc_1121_, 0) then
																				loc_1130_ = loc_1114_;
																				loc_1131_ = __spider_scoped_dependencies[7];
																				loc_1132_ = loc_1078_;
																				__spider_scoped_dependencies[7] = loc_1131_;
																				loc_1131_[1](loc_1091_, 32, loc_1109_, 0, loc_1120_, loc_1132_)
																				loc_1132_ = 1;
																				loc_1114_ = 0;
																			else
																				loc_1129_ = loc_1122_;
																				loc_1130_ = loc_1114_;
																				loc_1131_ = loc_1078_;
																				loc_1132_ = __spider_scoped_dependencies[7];
																				__spider_scoped_dependencies[7] = loc_1132_;
																				loc_1122_ = buffer_read_i32(loc_1081_[1], loc_1082_, 40);
																				loc_1132_ = 0;
																				loc_1114_ = loc_1130_;
																				loc_1078_ = loc_1131_;
																			end
																		end
																	elseif (loc_1132_) > 21 then
																		if (loc_1132_) < 25 then
																			if (loc_1132_) < 23 then
																				loc_1132_ = 9;
																			elseif (loc_1132_) > 23 then
																				loc_1132_ = 9;
																			else
																				loc_1132_ = 7;
																			end
																		elseif (loc_1132_) > 25 then
																			if (loc_1132_) < 27 then
																				loc_1132_ = 9;
																			else
																				loc_1132_ = 9;
																			end
																		else
																			loc_1132_ = 9;
																		end
																	else
																		loc_1132_ = 9;
																	end
																else
																	loc_1132_ = 9;
																end
															elseif (loc_1132_) > 28 then
																if (loc_1132_) < 42 then
																	if (loc_1132_) < 35 then
																		if (loc_1132_) < 32 then
																			if (loc_1132_) < 30 then
																				loc_1132_ = 9;
																			elseif (loc_1132_) > 30 then
																				loc_1132_ = 9;
																			else
																				loc_1132_ = 9;
																			end
																		elseif (loc_1132_) > 32 then
																			if (loc_1132_) < 34 then
																				loc_1132_ = 9;
																			else
																				loc_1132_ = loc_1114_;
																				loc_1114_ = rt_load_i32_from_u8(loc_1081_, loc_1082_, 40);
																				loc_1132_ = 2;
																			end
																		else
																			loc_1132_ = 3;
																		end
																	elseif (loc_1132_) > 35 then
																		if (loc_1132_) < 39 then
																			if (loc_1132_) < 37 then
																				loc_1132_ = 3;
																			elseif (loc_1132_) > 37 then
																				loc_1132_ = 3;
																			else
																				loc_1132_ = 3;
																			end
																		elseif (loc_1132_) > 39 then
																			if (loc_1132_) < 41 then
																				loc_1132_ = 4;
																			else
																				loc_1132_ = 9;
																			end
																		else
																			loc_1132_ = 9;
																		end
																	else
																		loc_1132_ = 4;
																	end
																elseif (loc_1132_) > 42 then
																	if (loc_1132_) < 49 then
																		if (loc_1132_) < 46 then
																			if (loc_1132_) < 44 then
																				loc_1132_ = 9;
																			elseif (loc_1132_) > 44 then
																				loc_1130_ = loc_1114_;
																				loc_1131_ = loc_1096_;
																				loc_1132_ = loc_1115_;
																				loc_1114_ = 0;
																				if (loc_1122_) >= 0 and (loc_1122_) < 8 then
																					if (loc_1122_) < 4 then
																						if (loc_1122_) < 2 then
																							if (loc_1122_) < 1 then
																								loc_1132_ = buffer_read_i32(loc_1081_[1], loc_1082_, 40);
																								rt_store_i32(loc_1081_, loc_1132_, 0, loc_1079_)
																								loc_1132_ = 10;
																								loc_1115_ = 1;
																								loc_1096_ = 65535;
																							else
																								loc_1132_ = buffer_read_i32(loc_1081_[1], loc_1082_, 40);
																								rt_store_i32(loc_1081_, loc_1132_, 0, loc_1079_)
																								loc_1132_ = 10;
																								loc_1115_ = 1;
																								loc_1096_ = 65535;
																							end
																						elseif (loc_1122_) > 2 then
																							loc_1132_ = buffer_read_i32(loc_1081_[1], loc_1082_, 40);
																							rt_store_i32_into_i16(loc_1081_, loc_1132_, 0, loc_1079_)
																							loc_1132_ = 10;
																							loc_1115_ = 1;
																							loc_1096_ = 65535;
																						else
																							loc_1132_ = buffer_read_i32(loc_1081_[1], loc_1082_, 40);
																							rt_store_i64(loc_1081_, loc_1132_, 0, rt_extend_s32_to_i64(rt_widen_i32(loc_1079_)))
																							loc_1132_ = 10;
																							loc_1115_ = 1;
																							loc_1096_ = 65535;
																						end
																					elseif (loc_1122_) > 4 then
																						if (loc_1122_) < 6 then
																							loc_1132_ = 10;
																							loc_1115_ = 1;
																							loc_1096_ = 65535;
																						elseif (loc_1122_) > 6 then
																							loc_1132_ = buffer_read_i32(loc_1081_[1], loc_1082_, 40);
																							rt_store_i64(loc_1081_, loc_1132_, 0, rt_extend_s32_to_i64(rt_widen_i32(loc_1079_)))
																							loc_1132_ = 10;
																							loc_1115_ = 1;
																							loc_1096_ = 65535;
																						else
																							loc_1132_ = buffer_read_i32(loc_1081_[1], loc_1082_, 40);
																							rt_store_i32(loc_1081_, loc_1132_, 0, loc_1079_)
																							loc_1132_ = 10;
																							loc_1115_ = 1;
																							loc_1096_ = 65535;
																						end
																					else
																						loc_1132_ = buffer_read_i32(loc_1081_[1], loc_1082_, 40);
																						rt_store_i32_into_i8(loc_1081_, loc_1132_, 0, loc_1079_)
																						loc_1132_ = 10;
																						loc_1115_ = 1;
																						loc_1096_ = 65535;
																					end
																				else
																					loc_1132_ = 10;
																					loc_1115_ = 1;
																					loc_1096_ = 65535;
																				end
																			else
																				loc_1130_ = __spider_scoped_dependencies[2];
																				loc_1132_ = loc_1119_;
																				__spider_scoped_dependencies[2] = loc_1130_;
																				loc_1131_ = buffer_read_i32(loc_1081_[1], 0, 70852);
																				loc_1132_ = loc_1078_;
																				loc_1119_ = loc_1130_[1](loc_1131_, loc_1132_)
																				loc_1132_ = 5;
																			end
																		elseif (loc_1132_) > 46 then
																			if (loc_1132_) < 48 then
																				loc_1132_ = loc_1090_;
																				loc_1132_ = 8;
																				if rt_greater_than_u32(loc_1121_, 8) then
																					loc_1131_ = loc_1120_;
																				else
																					loc_1130_ = loc_1121_;
																					loc_1131_ = loc_1120_;
																					loc_1121_ = loc_1132_;
																				end
																				loc_1132_ = 7;
																				loc_1120_ = rt_or_i32(loc_1131_, 8);
																				loc_1090_ = 120;
																			else
																				loc_1132_ = 9;
																			end
																		else
																			loc_1129_ = loc_1112_;
																			loc_1130_ = loc_1111_;
																			loc_1131_ = loc_1108_;
																			loc_1132_ = loc_1119_;
																			loc_1112_ = rt_load_i64(loc_1081_, loc_1082_, 40);
																			if rt_equal_i64(loc_1112_, into_bits_i64(0, 0)) then
																				loc_1119_ = loc_1107_;
																			else
																				loc_1131_ = loc_1107_;
																				loc_1132_ = loc_1107_;
																				loc_1107_ = loc_1132_;
																				loc_1119_ = loc_1132_;
																				repeat
																					rt_yield_budget = rt_yield_budget - 1
																					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																					loc_1132_ = loc_1114_;
																					loc_1119_ = bit32_or(loc_1119_ + -1, 0);
																					rt_store_i32_into_i8(loc_1081_, loc_1119_, 0, rt_or_i32(rt_and_i32(rt_narrow_i64(loc_1112_), 7), 48))
																					loc_1132_ = (rt_greater_than_u64(loc_1112_, into_bits_i64(7, 0)) and 1 or 0);
																					loc_1114_ = loc_1132_;
																					loc_1112_ = rt_shift_right_u64(loc_1112_, into_bits_i64(3, 0));
																				until loc_1132_ == 0
																			end
																			loc_1108_ = 0;
																			loc_1111_ = 1024;
																			if rt_equal_i32(rt_and_i32(loc_1120_, 8), 0) then
																				loc_1132_ = 8;
																			else
																				loc_1132_ = loc_1114_;
																				loc_1132_ = bit32_or(loc_1100_ - loc_1119_, 0);
																				if rt_greater_than_s32(loc_1121_, loc_1132_) then
																					loc_1114_ = loc_1132_;
																				else
																					loc_1114_ = loc_1132_;
																					loc_1131_ = loc_1121_;
																					loc_1121_ = loc_1132_;
																				end
																				loc_1132_ = 8;
																			end
																		end
																	elseif (loc_1132_) > 49 then
																		if (loc_1132_) < 53 then
																			if (loc_1132_) < 51 then
																				loc_1131_ = loc_1119_;
																				loc_1132_ = loc_1114_;
																				loc_1119_ = buffer_read_i32(loc_1081_[1], loc_1082_, 40);
																				loc_1132_ = 1108;
																				if rt_not_equal_i32(loc_1119_, 0) then
																					loc_1114_ = loc_1119_;
																				else
																					loc_1114_ = loc_1119_;
																					loc_1131_ = loc_1119_;
																					loc_1119_ = loc_1132_;
																				end
																				loc_1132_ = 5;
																			elseif (loc_1132_) > 51 then
																				loc_1130_ = loc_1112_;
																				loc_1131_ = loc_1111_;
																				loc_1132_ = loc_1108_;
																				loc_1112_ = rt_load_i64(loc_1081_, loc_1082_, 40);
																				loc_1132_ = 6;
																				loc_1108_ = 0;
																				loc_1111_ = 1024;
																			else
																				loc_1132_ = 9;
																			end
																		elseif (loc_1132_) > 53 then
																			if (loc_1132_) < 55 then
																				loc_1132_ = 9;
																			else
																				loc_1132_ = 7;
																			end
																		else
																			loc_1132_ = 9;
																		end
																	else
																		loc_1132_ = 9;
																	end
																else
																	loc_1132_ = 9;
																end
															else
																loc_1132_ = 9;
															end
														else
															loc_1132_ = 9;
														end
														if (loc_1132_) >= 0 and (loc_1132_) < 10 then
															if (loc_1132_) < 5 then
																if (loc_1132_) < 2 then
																	if (loc_1132_) < 1 then
																		loc_1130_ = loc_1090_;
																		loc_1131_ = loc_1119_;
																		loc_1132_ = loc_1114_;
																		loc_1131_ = loc_1115_;
																		loc_1130_ = loc_1096_;
																		loc_1114_ = 0;
																		loc_1119_ = loc_1122_;
																		loc_1132_ = loc_1122_;
																		repeat
																			rt_yield_budget = rt_yield_budget - 1
																			if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																			loc_1129_ = loc_1118_;
																			loc_1118_ = buffer_read_i32(loc_1081_[1], loc_1119_, 0);
																			if rt_equal_i32(loc_1118_, 0) then
																				loc_1129_ = 0;
																				loc_1130_ = 1;
																			else
																				loc_1131_ = loc_1078_;
																				loc_1118_ = __spider_scoped_dependencies[4][1](bit32_or(loc_1082_ + 4, 0), loc_1118_, loc_1131_)
																				if rt_less_than_s32(loc_1118_, 0) then
																					loc_1129_ = 0;
																					loc_1130_ = 2;
																				else
																					if rt_greater_than_u32(loc_1118_, bit32_or(loc_1121_ - loc_1114_, 0)) then
																						loc_1129_ = 0;
																						loc_1130_ = 1;
																					else
																						loc_1114_ = bit32_or(loc_1118_ + loc_1114_, 0);
																						loc_1119_ = bit32_or(loc_1119_ + 4, 0);
																						if rt_less_than_u32(loc_1114_, loc_1121_) then
																							loc_1129_ = 1;
																							loc_1130_ = 65535;
																						else
																							loc_1129_ = 0;
																							loc_1130_ = 0;
																						end
																					end
																				end
																			end
																			loc_1131_ = loc_1129_;
																		until loc_1129_ == 0
																		if (loc_1130_) >= 0 and (loc_1130_) < 2 then
																			if (loc_1130_) < 1 then
																				loc_1129_ = loc_1131_;
																				loc_1131_ = 0;
																				loc_1115_ = loc_1129_;
																				loc_1096_ = loc_1130_;
																			else
																				loc_1129_ = loc_1131_;
																				loc_1131_ = 0;
																				loc_1115_ = loc_1129_;
																				loc_1096_ = loc_1130_;
																			end
																		else
																			loc_1131_ = 1;
																			loc_1115_ = 0;
																			loc_1096_ = 24;
																		end
																		if rt_not_equal_i32(loc_1131_, 0) then
																			loc_1122_ = 4;
																		else
																			if rt_less_than_s32(loc_1114_, 0) then
																				loc_1130_ = loc_1132_;
																				loc_1131_ = loc_1096_;
																				loc_1132_ = loc_1115_;
																				loc_1122_ = 4;
																				loc_1115_ = 0;
																				loc_1096_ = 14;
																			else
																				loc_1130_ = loc_1132_;
																				loc_1131_ = loc_1096_;
																				loc_1132_ = loc_1115_;
																				loc_1129_ = loc_1078_;
																				__spider_scoped_dependencies[7][1](loc_1091_, 32, loc_1109_, loc_1114_, loc_1120_, loc_1129_)
																				if rt_not_equal_i32(loc_1114_, 0) then
																					loc_1096_ = loc_1131_;
																					loc_1115_ = loc_1132_;
																					loc_1131_ = loc_1119_;
																					loc_1132_ = loc_1130_;
																					loc_1119_ = 0;
																					repeat
																						rt_yield_budget = rt_yield_budget - 1
																						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																						loc_1129_ = loc_1118_;
																						loc_1130_ = loc_1096_;
																						loc_1131_ = loc_1115_;
																						loc_1118_ = buffer_read_i32(loc_1081_[1], loc_1132_, 0);
																						if rt_equal_i32(loc_1118_, 0) then
																							loc_1131_ = 0;
																							loc_1096_ = 1;
																						else
																							loc_1131_ = loc_1078_;
																							loc_1118_ = __spider_scoped_dependencies[4][1](bit32_or(loc_1082_ + 4, 0), loc_1118_, loc_1131_)
																							loc_1119_ = bit32_or(loc_1118_ + loc_1119_, 0);
																							if rt_greater_than_u32(loc_1119_, loc_1114_) then
																								loc_1131_ = 0;
																								loc_1096_ = 1;
																							else
																								loc_1131_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																								if not (rt_not_equal_i32(rt_and_i32(loc_1131_, 32), 0)) then
																									loc_1130_ = __spider_scoped_dependencies[1];
																									__spider_scoped_dependencies[1] = loc_1130_;
																									loc_1131_ = loc_1078_;
																									loc_1131_ = loc_1130_[1](bit32_or(loc_1082_ + 4, 0), loc_1118_, loc_1091_, loc_1131_)
																								end
																								loc_1132_ = bit32_or(loc_1132_ + 4, 0);
																								if rt_less_than_u32(loc_1119_, loc_1114_) then
																									loc_1131_ = 1;
																									loc_1096_ = 65535;
																								else
																									loc_1131_ = 0;
																									loc_1096_ = 0;
																								end
																							end
																						end
																						loc_1115_ = loc_1131_;
																					until loc_1131_ == 0
																					if rt_not_equal_i32(loc_1096_, 0) then
																						loc_1122_ = 0;
																					else
																						loc_1122_ = 0;
																					end
																				else
																					loc_1096_ = loc_1131_;
																					loc_1115_ = loc_1132_;
																					loc_1131_ = loc_1119_;
																					loc_1132_ = loc_1114_;
																					loc_1122_ = 0;
																					loc_1114_ = 0;
																					loc_1119_ = loc_1131_;
																				end
																			end
																		end
																	else
																		loc_1131_ = loc_1090_;
																		loc_1132_ = loc_1122_;
																		loc_1122_ = 0;
																	end
																elseif (loc_1132_) > 2 then
																	if (loc_1132_) < 4 then
																		loc_1132_ = loc_1114_;
																		loc_1114_ = (rt_less_than_s32(loc_1121_, 0) and 1 or 0);
																		if rt_not_equal_i32(rt_and_i32(loc_1110_, loc_1114_), 0) then
																			loc_1123_ = loc_1115_;
																			loc_1115_ = loc_1122_;
																			loc_1122_ = loc_1096_;
																			loc_1096_ = loc_1090_;
																			loc_1122_ = 4;
																			loc_1115_ = 0;
																			loc_1096_ = 15;
																		else
																			loc_1123_ = loc_1115_;
																			loc_1115_ = loc_1122_;
																			loc_1122_ = loc_1096_;
																			loc_1096_ = loc_1090_;
																			loc_1132_ = loc_1119_;
																			loc_1131_ = rt_load_f64(loc_1081_, loc_1082_, 40);
																			rt_store_i32(loc_1081_, loc_1082_, 92, 0)
																			if rt_greater_than_s64(rt_transmute_f64_to_i64(loc_1131_), into_bits_i64(4294967295, 4294967295)) then
																				loc_1119_ = loc_1102_;
																				loc_1102_ = loc_1116_;
																				loc_1127_ = loc_1111_;
																				loc_1111_ = loc_1114_;
																				loc_1114_ = loc_1122_;
																				loc_1128_ = loc_1110_;
																				loc_1110_ = loc_1115_;
																				loc_1115_ = loc_1123_;
																				loc_1123_ = loc_1082_;
																				loc_1129_ = loc_1117_;
																				loc_1130_ = loc_1118_;
																				loc_1118_ = loc_1096_;
																				loc_1132_ = loc_1078_;
																				if rt_equal_i32(rt_and_i32(loc_1120_, 2048), 0) then
																					loc_1126_ = rt_and_i32(loc_1120_, 1);
																					loc_1117_ = 1040;
																					loc_1125_ = 1035;
																					if not (rt_not_equal_i32(loc_1126_, 0)) then
																						loc_1124_ = loc_1117_;
																						loc_1117_ = loc_1125_;
																					end
																					loc_1116_ = loc_1126_;
																					loc_1096_ = (rt_equal_i32(loc_1126_, 0) and 1 or 0);
																				else
																					loc_1116_ = 1;
																					loc_1096_ = 0;
																					loc_1117_ = 1037;
																				end
																			else
																				loc_1119_ = loc_1102_;
																				loc_1102_ = loc_1116_;
																				loc_1127_ = loc_1111_;
																				loc_1111_ = loc_1114_;
																				loc_1114_ = loc_1122_;
																				loc_1128_ = loc_1110_;
																				loc_1110_ = loc_1115_;
																				loc_1115_ = loc_1123_;
																				loc_1123_ = loc_1082_;
																				loc_1129_ = loc_1117_;
																				loc_1130_ = loc_1118_;
																				loc_1118_ = loc_1096_;
																				loc_1132_ = loc_1078_;
																				loc_1131_ = rt_negate_f64(loc_1131_);
																				loc_1116_ = 1;
																				loc_1096_ = 0;
																				loc_1117_ = 1034;
																			end
																			if rt_less_than_f64(loc_1131_, from_bits_f64(0, 2146435072) --[[ inf_f64 ]]) then
																				loc_1132_ = __spider_scoped_dependencies[5][1](loc_1131_, bit32_or(loc_1123_ + 92, 0), loc_1132_)
																				loc_1122_ = rt_add_f64(loc_1132_, loc_1132_);
																				if rt_equal_f64(loc_1122_, from_bits_f64(0, 0) --[[ 0_f64 ]]) then
																					loc_1090_ = rt_or_i32(loc_1118_, 32);
																					if rt_equal_i32(loc_1090_, 97) then
																						loc_1132_ = 1;
																					else
																						loc_1131_ = loc_1108_;
																						loc_1132_ = loc_1110_;
																						loc_1108_ = 6;
																						if rt_not_equal_i32(loc_1111_, 0) then
																							loc_1132_ = loc_1121_;
																						else
																							loc_1131_ = loc_1108_;
																							loc_1132_ = loc_1121_;
																							loc_1108_ = loc_1132_;
																						end
																						loc_1110_ = buffer_read_i32(loc_1081_[1], loc_1123_, 92);
																						loc_1132_ = 0;
																					end
																				else
																					loc_1130_ = buffer_read_i32(loc_1081_[1], loc_1123_, 92);
																					rt_store_i32(loc_1081_, loc_1123_, 92, bit32_or(loc_1130_ + -1, 0))
																					loc_1090_ = rt_or_i32(loc_1118_, 32);
																					if rt_not_equal_i32(loc_1090_, 97) then
																						loc_1128_ = loc_1108_;
																						loc_1129_ = loc_1110_;
																						loc_1131_ = loc_1122_;
																						loc_1132_ = loc_1121_;
																						loc_1110_ = bit32_or(loc_1130_ + -29, 0);
																						rt_store_i32(loc_1081_, loc_1123_, 92, loc_1110_)
																						loc_1108_ = 6;
																						if rt_not_equal_i32(loc_1111_, 0) then
																							loc_1121_ = loc_1132_;
																						else
																							loc_1121_ = loc_1132_;
																							loc_1130_ = loc_1108_;
																							loc_1108_ = loc_1132_;
																						end
																						loc_1132_ = 0;
																						loc_1122_ = rt_multiply_f64(loc_1131_, from_bits_f64(0, 1102053376) --[[ 268435456_f64 ]]);
																					else
																						loc_1128_ = loc_1108_;
																						loc_1129_ = loc_1110_;
																						loc_1131_ = loc_1122_;
																						loc_1132_ = loc_1130_;
																						loc_1130_ = loc_1121_;
																						loc_1132_ = 1;
																						loc_1110_ = loc_1129_;
																						loc_1108_ = loc_1128_;
																						loc_1121_ = loc_1130_;
																						loc_1122_ = loc_1131_;
																					end
																				end
																				if rt_not_equal_i32(loc_1132_, 0) then
																					loc_1108_ = bit32_or(loc_1117_ + rt_and_i32(rt_shift_right_s32(rt_shift_left_i32(loc_1118_, 26), 31), 9), 0);
																					if not (rt_greater_than_u32(loc_1121_, 11)) then
																						loc_1117_ = loc_1122_;
																						loc_1122_ = bit32_or(12 - loc_1121_, 0);
																						loc_1114_ = rt_and_i32(loc_1122_, 7);
																						if rt_not_equal_i32(loc_1114_, 0) then
																							loc_1115_ = bit32_or(loc_1121_ + -12, 0);
																							loc_1122_ = from_bits_f64(0, 1076887552) --[[ 16_f64 ]];
																							repeat
																								rt_yield_budget = rt_yield_budget - 1
																								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																								loc_1115_ = bit32_or(loc_1115_ + 1, 0);
																								loc_1111_ = bit32_or(loc_1114_ + -1, 0);
																								loc_1114_ = loc_1111_;
																								loc_1122_ = rt_multiply_f64(loc_1122_, from_bits_f64(0, 1076887552) --[[ 16_f64 ]]);
																							until loc_1111_ == 0
																							loc_1115_ = bit32_or(0 - loc_1115_, 0);
																						else
																							loc_1115_ = loc_1114_;
																							loc_1115_ = loc_1122_;
																							loc_1122_ = from_bits_f64(0, 1076887552) --[[ 16_f64 ]];
																						end
																						if not (rt_greater_than_u32(loc_1121_, 4)) then
																							repeat
																								rt_yield_budget = rt_yield_budget - 1
																								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																								loc_1114_ = bit32_or(loc_1115_ + -8, 0);
																								loc_1115_ = loc_1114_;
																								loc_1122_ = rt_multiply_f64(rt_multiply_f64(rt_multiply_f64(rt_multiply_f64(rt_multiply_f64(rt_multiply_f64(rt_multiply_f64(rt_multiply_f64(loc_1122_, from_bits_f64(0, 1076887552) --[[ 16_f64 ]]), from_bits_f64(0, 1076887552) --[[ 16_f64 ]]), from_bits_f64(0, 1076887552) --[[ 16_f64 ]]), from_bits_f64(0, 1076887552) --[[ 16_f64 ]]), from_bits_f64(0, 1076887552) --[[ 16_f64 ]]), from_bits_f64(0, 1076887552) --[[ 16_f64 ]]), from_bits_f64(0, 1076887552) --[[ 16_f64 ]]), from_bits_f64(0, 1076887552) --[[ 16_f64 ]]);
																							until loc_1114_ == 0
																						end
																						loc_1115_ = rt_load_i32_from_u8(loc_1081_, loc_1108_, 0);
																						if rt_not_equal_i32(loc_1115_, 45) then
																							loc_1122_ = rt_subtract_f64(rt_add_f64(loc_1117_, loc_1122_), loc_1122_);
																						else
																							loc_1122_ = rt_negate_f64(rt_add_f64(loc_1122_, rt_subtract_f64(rt_negate_f64(loc_1117_), loc_1122_)));
																						end
																					end
																					loc_1117_ = buffer_read_i32(loc_1081_[1], loc_1123_, 92);
																					if rt_equal_i32(loc_1117_, 0) then
																						rt_store_i32_into_i8(loc_1081_, loc_1123_, 63, 48)
																						loc_1102_ = loc_1119_;
																					else
																						loc_1115_ = loc_1119_;
																						loc_1119_ = loc_1098_;
																						loc_1098_ = loc_1119_;
																						loc_1102_ = loc_1115_;
																						loc_1115_ = rt_shift_right_s32(loc_1117_, 31);
																						loc_1115_ = bit32_or(rt_exclusive_or_i32(loc_1117_, loc_1115_) - loc_1115_, 0);
																						repeat
																							rt_yield_budget = rt_yield_budget - 1
																							if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																							loc_1114_ = loc_1115_;
																							loc_1119_ = bit32_or(loc_1119_ + -1, 0);
																							loc_1111_ = rt_divide_u32(loc_1114_, 10);
																							rt_store_i32_into_i8(loc_1081_, loc_1119_, 0, rt_or_i32(bit32_or(loc_1114_ - rt_multiply_i32(loc_1111_, 10), 0), 48))
																							loc_1115_ = loc_1111_;
																						until not (rt_equal_i32((rt_less_than_u32(loc_1114_, 10) and 1 or 0), 0))
																					end
																					loc_1110_ = bit32_or(loc_1119_ + -2, 0);
																					rt_store_i32_into_i8(loc_1081_, loc_1110_, 0, bit32_or(loc_1118_ + 15, 0))
																					loc_1118_ = rt_and_i32(loc_1118_, 32);
																					loc_1116_ = rt_or_i32(loc_1116_, 2);
																					loc_1115_ = bit32_or(loc_1119_ + -1, 0);
																					loc_1119_ = 45;
																					loc_1114_ = 43;
																					if not (rt_less_than_s32(loc_1117_, 0)) then
																						loc_1119_ = loc_1114_;
																					end
																					rt_store_i32_into_i8(loc_1081_, loc_1115_, 0, loc_1119_)
																					loc_1082_ = loc_1123_;
																					loc_1119_ = bit32_or(loc_1123_ + 64, 0);
																					loc_1123_ = rt_and_i32((rt_equal_i32(rt_and_i32(loc_1120_, 8), 0) and 1 or 0), (rt_less_than_s32(loc_1121_, 1) and 1 or 0));
																					repeat
																						rt_yield_budget = rt_yield_budget - 1
																						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																						loc_1114_ = loc_1122_;
																						loc_1115_ = rt_saturate_f64_to_s32(loc_1114_);
																						loc_1122_ = rt_load_i32_from_u8(loc_1081_, bit32_or(loc_1115_ + 6448, 0), 0);
																						rt_store_i32_into_i8(loc_1081_, loc_1119_, 0, rt_or_i32(loc_1122_, loc_1118_))
																						loc_1122_ = bit32_or(loc_1119_ + 1, 0);
																						loc_1115_ = rt_multiply_f64(rt_subtract_f64(loc_1114_, rt_convert_s32_to_f64(loc_1115_)), from_bits_f64(0, 1076887552) --[[ 16_f64 ]]);
																						if rt_not_equal_i32(bit32_or(loc_1122_ - bit32_or(loc_1082_ + 64, 0), 0), 1) then
																							loc_1119_, loc_1122_ = loc_1122_, loc_1119_;
																						else
																							loc_1119_, loc_1122_ = loc_1122_, loc_1119_;
																							if not (rt_not_equal_i32(rt_and_i32(loc_1123_, (rt_equal_f64(loc_1115_, from_bits_f64(0, 0) --[[ 0_f64 ]]) and 1 or 0)), 0)) then
																								rt_store_i32_into_i8(loc_1081_, loc_1122_, 1, 46)
																								loc_1119_ = bit32_or(loc_1122_ + 2, 0);
																							end
																						end
																						loc_1122_ = loc_1115_;
																					until not (rt_not_equal_f64(loc_1115_, from_bits_f64(0, 0) --[[ 0_f64 ]]))
																					loc_1111_ = bit32_or(loc_1098_ - loc_1110_, 0);
																					loc_1114_ = bit32_or(loc_1111_ + loc_1116_, 0);
																					if rt_greater_than_s32(loc_1121_, bit32_or(2147483645 - loc_1114_, 0)) then
																						loc_1122_ = 4;
																						loc_1115_ = 0;
																						loc_1096_ = 20;
																					else
																						loc_1122_ = loc_1117_;
																						loc_1123_ = loc_1118_;
																						loc_1119_ = bit32_or(loc_1119_ - bit32_or(loc_1082_ + 64, 0), 0);
																						loc_1117_ = bit32_or(loc_1121_ + 2, 0);
																						if rt_less_than_s32(bit32_or(loc_1119_ + -2, 0), loc_1121_) then
																							loc_1122_ = loc_1119_;
																							loc_1123_ = loc_1114_;
																							loc_1114_ = loc_1109_;
																						else
																							loc_1118_ = loc_1117_;
																							loc_1122_ = loc_1119_;
																							loc_1123_ = loc_1114_;
																							loc_1114_ = loc_1109_;
																							loc_1117_ = loc_1119_;
																						end
																						if rt_not_equal_i32(loc_1121_, 0) then
																							loc_1118_ = loc_1122_;
																						else
																							loc_1118_ = loc_1122_;
																							loc_1119_ = loc_1117_;
																							loc_1117_ = loc_1122_;
																						end
																						loc_1123_ = bit32_or(loc_1117_ + loc_1123_, 0);
																						loc_1122_ = rt_and_i32(loc_1120_, 73728);
																						if not (rt_not_equal_i32(loc_1122_, 0)) then
																							if not (rt_less_than_equal_s32(loc_1114_, loc_1123_)) then
																								loc_1120_ = bit32_or(loc_1114_ - loc_1123_, 0);
																								loc_1121_ = (rt_less_than_u32(loc_1120_, 256) and 1 or 0);
																								loc_1115_ = 256;
																								if rt_not_equal_i32(loc_1121_, 0) then
																									loc_1119_ = loc_1120_;
																								else
																									loc_1119_ = loc_1120_;
																									loc_1120_ = loc_1115_;
																								end
																								if not (rt_equal_i32(loc_1120_, 0)) then
																									rt_memory_fill(loc_1081_, bit32_or(loc_1082_ + 608, 0), 32, loc_1120_)
																								end
																								if not (rt_not_equal_i32(loc_1121_, 0)) then
																									repeat
																										rt_yield_budget = rt_yield_budget - 1
																										if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																										loc_1115_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																										if not (rt_not_equal_i32(rt_and_i32(loc_1115_, 32), 0)) then
																											loc_1109_ = __spider_scoped_dependencies[1];
																											__spider_scoped_dependencies[1] = loc_1109_;
																											loc_1115_ = loc_1078_;
																											loc_1115_ = loc_1109_[1](bit32_or(loc_1082_ + 608, 0), 256, loc_1091_, loc_1115_)
																										end
																										loc_1115_ = bit32_or(loc_1119_ + -256, 0);
																										loc_1119_ = loc_1115_;
																									until not (rt_greater_than_u32(loc_1115_, 255))
																								end
																								loc_1115_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																								if not (rt_not_equal_i32(rt_and_i32(loc_1115_, 32), 0)) then
																									loc_1109_ = __spider_scoped_dependencies[1];
																									__spider_scoped_dependencies[1] = loc_1109_;
																									loc_1115_ = loc_1078_;
																									loc_1119_ = loc_1109_[1](bit32_or(loc_1082_ + 608, 0), loc_1119_, loc_1091_, loc_1115_)
																								end
																							end
																						end
																						loc_1119_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																						if not (rt_not_equal_i32(rt_and_i32(loc_1119_, 32), 0)) then
																							loc_1115_ = __spider_scoped_dependencies[1];
																							__spider_scoped_dependencies[1] = loc_1115_;
																							loc_1119_ = loc_1078_;
																							loc_1119_ = loc_1115_[1](loc_1108_, loc_1116_, loc_1091_, loc_1119_)
																						end
																						if not (rt_not_equal_i32(loc_1122_, 65536)) then
																							if not (rt_less_than_equal_s32(loc_1114_, loc_1123_)) then
																								loc_1119_ = loc_1116_;
																								loc_1116_ = bit32_or(loc_1114_ - loc_1123_, 0);
																								loc_1121_ = (rt_less_than_u32(loc_1116_, 256) and 1 or 0);
																								loc_1115_ = 256;
																								if rt_not_equal_i32(loc_1121_, 0) then
																									loc_1119_ = loc_1116_;
																								else
																									loc_1119_ = loc_1116_;
																									loc_1116_ = loc_1115_;
																								end
																								if not (rt_equal_i32(loc_1116_, 0)) then
																									rt_memory_fill(loc_1081_, bit32_or(loc_1082_ + 608, 0), 48, loc_1116_)
																								end
																								if not (rt_not_equal_i32(loc_1121_, 0)) then
																									repeat
																										rt_yield_budget = rt_yield_budget - 1
																										if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																										loc_1115_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																										if not (rt_not_equal_i32(rt_and_i32(loc_1115_, 32), 0)) then
																											loc_1109_ = __spider_scoped_dependencies[1];
																											__spider_scoped_dependencies[1] = loc_1109_;
																											loc_1115_ = loc_1078_;
																											loc_1115_ = loc_1109_[1](bit32_or(loc_1082_ + 608, 0), 256, loc_1091_, loc_1115_)
																										end
																										loc_1115_ = bit32_or(loc_1119_ + -256, 0);
																										loc_1119_ = loc_1115_;
																									until not (rt_greater_than_u32(loc_1115_, 255))
																								end
																								loc_1115_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																								if not (rt_not_equal_i32(rt_and_i32(loc_1115_, 32), 0)) then
																									loc_1109_ = __spider_scoped_dependencies[1];
																									__spider_scoped_dependencies[1] = loc_1109_;
																									loc_1115_ = loc_1078_;
																									loc_1119_ = loc_1109_[1](bit32_or(loc_1082_ + 608, 0), loc_1119_, loc_1091_, loc_1115_)
																								end
																							end
																						end
																						loc_1119_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																						if not (rt_not_equal_i32(rt_and_i32(loc_1119_, 32), 0)) then
																							loc_1115_ = __spider_scoped_dependencies[1];
																							__spider_scoped_dependencies[1] = loc_1115_;
																							loc_1119_ = loc_1078_;
																							loc_1119_ = loc_1115_[1](bit32_or(loc_1082_ + 64, 0), loc_1118_, loc_1091_, loc_1119_)
																						end
																						loc_1119_ = bit32_or(loc_1117_ - loc_1118_, 0);
																						if not (rt_less_than_s32(loc_1119_, 1)) then
																							loc_1118_ = (rt_less_than_u32(loc_1119_, 256) and 1 or 0);
																							loc_1115_ = 256;
																							if rt_not_equal_i32(loc_1118_, 0) then
																								loc_1117_ = loc_1119_;
																							else
																								loc_1117_ = loc_1119_;
																								loc_1117_ = loc_1115_;
																							end
																							if not (rt_equal_i32(loc_1117_, 0)) then
																								rt_memory_fill(loc_1081_, bit32_or(loc_1082_ + 608, 0), 48, loc_1117_)
																							end
																							if not (rt_not_equal_i32(loc_1118_, 0)) then
																								repeat
																									rt_yield_budget = rt_yield_budget - 1
																									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																									loc_1115_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																									if not (rt_not_equal_i32(rt_and_i32(loc_1115_, 32), 0)) then
																										loc_1109_ = __spider_scoped_dependencies[1];
																										__spider_scoped_dependencies[1] = loc_1109_;
																										loc_1115_ = loc_1078_;
																										loc_1115_ = loc_1109_[1](bit32_or(loc_1082_ + 608, 0), 256, loc_1091_, loc_1115_)
																									end
																									loc_1115_ = bit32_or(loc_1119_ + -256, 0);
																									loc_1119_ = loc_1115_;
																								until not (rt_greater_than_u32(loc_1115_, 255))
																							end
																							loc_1115_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																							if not (rt_not_equal_i32(rt_and_i32(loc_1115_, 32), 0)) then
																								loc_1109_ = __spider_scoped_dependencies[1];
																								__spider_scoped_dependencies[1] = loc_1109_;
																								loc_1115_ = loc_1078_;
																								loc_1119_ = loc_1109_[1](bit32_or(loc_1082_ + 608, 0), loc_1119_, loc_1091_, loc_1115_)
																							end
																						end
																						loc_1119_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																						if not (rt_not_equal_i32(rt_and_i32(loc_1119_, 32), 0)) then
																							loc_1115_ = __spider_scoped_dependencies[1];
																							__spider_scoped_dependencies[1] = loc_1115_;
																							loc_1119_ = loc_1078_;
																							loc_1119_ = loc_1115_[1](loc_1110_, loc_1111_, loc_1091_, loc_1119_)
																						end
																						if not (rt_not_equal_i32(loc_1122_, 8192)) then
																							if not (rt_less_than_equal_s32(loc_1114_, loc_1123_)) then
																								loc_1122_ = loc_1118_;
																								loc_1119_ = bit32_or(loc_1114_ - loc_1123_, 0);
																								loc_1118_ = (rt_less_than_u32(loc_1119_, 256) and 1 or 0);
																								loc_1115_ = 256;
																								if rt_not_equal_i32(loc_1118_, 0) then
																									loc_1122_ = loc_1119_;
																								else
																									loc_1122_ = loc_1119_;
																									loc_1119_ = loc_1115_;
																								end
																								if not (rt_equal_i32(loc_1119_, 0)) then
																									rt_memory_fill(loc_1081_, bit32_or(loc_1082_ + 608, 0), 32, loc_1119_)
																								end
																								if not (rt_not_equal_i32(loc_1118_, 0)) then
																									repeat
																										rt_yield_budget = rt_yield_budget - 1
																										if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																										loc_1119_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																										if not (rt_not_equal_i32(rt_and_i32(loc_1119_, 32), 0)) then
																											loc_1115_ = __spider_scoped_dependencies[1];
																											__spider_scoped_dependencies[1] = loc_1115_;
																											loc_1119_ = loc_1078_;
																											loc_1119_ = loc_1115_[1](bit32_or(loc_1082_ + 608, 0), 256, loc_1091_, loc_1119_)
																										end
																										loc_1119_ = bit32_or(loc_1122_ + -256, 0);
																										loc_1122_ = loc_1119_;
																									until not (rt_greater_than_u32(loc_1119_, 255))
																								end
																								loc_1119_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																								if not (rt_not_equal_i32(rt_and_i32(loc_1119_, 32), 0)) then
																									loc_1115_ = __spider_scoped_dependencies[1];
																									__spider_scoped_dependencies[1] = loc_1115_;
																									loc_1119_ = loc_1078_;
																									loc_1122_ = loc_1115_[1](bit32_or(loc_1082_ + 608, 0), loc_1122_, loc_1091_, loc_1119_)
																								end
																							end
																						end
																						if rt_greater_than_s32(loc_1114_, loc_1123_) then
																							loc_1109_ = loc_1114_;
																							loc_1119_ = loc_1123_;
																						else
																							loc_1109_ = loc_1114_;
																							loc_1119_ = loc_1123_;
																							loc_1122_ = loc_1114_;
																							loc_1114_ = loc_1123_;
																						end
																						loc_1122_ = 4;
																						loc_1115_ = 1;
																						loc_1096_ = 65535;
																					end
																				else
																					loc_1125_ = (rt_less_than_s32(loc_1110_, 0) and 1 or 0);
																					loc_1130_ = bit32_or(loc_1123_ + 96, 0);
																					loc_1132_ = 0;
																					loc_1131_ = 288;
																					if rt_not_equal_i32(loc_1125_, 0) then
																						loc_1082_ = loc_1123_;
																						loc_1123_ = loc_1115_;
																						loc_1124_ = loc_1117_;
																						loc_1126_ = loc_1122_;
																						loc_1122_ = loc_1114_;
																						loc_1127_ = loc_1118_;
																						loc_1118_ = loc_1131_;
																						loc_1128_ = loc_1111_;
																						loc_1129_ = loc_1090_;
																						loc_1090_ = loc_1096_;
																						loc_1096_ = loc_1116_;
																						loc_1116_ = loc_1102_;
																						loc_1102_ = loc_1119_;
																						loc_1119_ = loc_1130_;
																						loc_1130_ = loc_1110_;
																						loc_1131_ = loc_1108_;
																					else
																						loc_1082_ = loc_1123_;
																						loc_1123_ = loc_1115_;
																						loc_1124_ = loc_1117_;
																						loc_1126_ = loc_1122_;
																						loc_1122_ = loc_1114_;
																						loc_1127_ = loc_1118_;
																						loc_1118_ = loc_1131_;
																						loc_1128_ = loc_1111_;
																						loc_1129_ = loc_1090_;
																						loc_1090_ = loc_1096_;
																						loc_1096_ = loc_1116_;
																						loc_1116_ = loc_1102_;
																						loc_1102_ = loc_1119_;
																						loc_1119_ = loc_1130_;
																						loc_1130_ = loc_1110_;
																						loc_1131_ = loc_1108_;
																						loc_1132_ = loc_1118_;
																					end
																					loc_1111_ = bit32_or(loc_1119_ + loc_1132_, 0);
																					loc_1132_ = loc_1111_;
																					repeat
																						rt_yield_budget = rt_yield_budget - 1
																						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																						loc_1119_ = rt_saturate_f64_to_u32(loc_1126_);
																						rt_store_i32(loc_1081_, loc_1132_, 0, loc_1119_)
																						loc_1128_ = loc_1119_;
																						loc_1132_ = bit32_or(loc_1132_ + 4, 0);
																						loc_1119_ = rt_multiply_f64(rt_subtract_f64(loc_1126_, rt_convert_u32_to_f64(loc_1119_)), from_bits_f64(0, 1104006501) --[[ 1000000000_f64 ]]);
																						loc_1126_ = loc_1119_;
																					until not (rt_not_equal_f64(loc_1119_, from_bits_f64(0, 0) --[[ 0_f64 ]]))
																					if rt_greater_than_equal_s32(loc_1130_, 1) then
																						loc_1118_ = loc_1111_;
																						repeat
																							rt_yield_budget = rt_yield_budget - 1
																							if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																							loc_1128_ = 29;
																							if rt_less_than_u32(loc_1130_, 29) then
																								loc_1128_, loc_1130_ = loc_1130_, loc_1128_;
																								loc_1130_, loc_1132_ = loc_1132_, loc_1130_;
																							else
																								loc_1128_, loc_1130_ = loc_1130_, loc_1128_;
																								loc_1130_, loc_1132_ = loc_1132_, loc_1130_;
																								loc_1128_ = loc_1132_;
																							end
																							loc_1132_ = bit32_or(loc_1130_ + -4, 0);
																							if not (rt_less_than_u32(loc_1132_, loc_1118_)) then
																								loc_1119_ = loc_1128_;
																								loc_1128_ = loc_1112_;
																								loc_1128_ = loc_1119_;
																								loc_1112_ = into_bits_i64(0, 0);
																								loc_1119_ = rt_widen_i32(loc_1119_);
																								repeat
																									rt_yield_budget = rt_yield_budget - 1
																									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																									loc_1115_ = loc_1118_;
																									loc_1118_ = loc_1113_;
																									loc_1118_ = rt_load_i64_from_u32(loc_1081_, loc_1132_, 0);
																									loc_1113_ = rt_add_i64(rt_shift_left_i64(loc_1118_, loc_1119_), loc_1112_);
																									loc_1114_ = rt_divide_u64(loc_1113_, into_bits_i64(1000000000, 0));
																									rt_store_i64_into_i32(loc_1081_, loc_1132_, 0, rt_subtract_i64(loc_1113_, rt_multiply_i64(loc_1114_, into_bits_i64(1000000000, 0))))
																									loc_1117_ = bit32_or(loc_1132_ + -4, 0);
																									loc_1132_ = loc_1117_;
																									loc_1118_ = loc_1115_;
																									loc_1112_ = loc_1114_;
																								until not (rt_greater_than_equal_u32(loc_1117_, loc_1115_))
																								if not (rt_less_than_u64(loc_1113_, into_bits_i64(1000000000, 0))) then
																									loc_1118_ = bit32_or(loc_1118_ + -4, 0);
																									rt_store_i64_into_i32(loc_1081_, loc_1118_, 0, loc_1112_)
																								end
																							end
																							repeat
																								rt_yield_budget = rt_yield_budget - 1
																								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																								loc_1122_, loc_1132_ = loc_1132_, loc_1122_;
																								loc_1132_, loc_1123_ = loc_1123_, loc_1132_;
																								if rt_less_than_equal_u32(loc_1130_, loc_1118_) then
																									loc_1132_ = loc_1130_;
																									loc_1119_ = 0;
																									loc_1122_ = 1;
																								else
																									loc_1132_ = loc_1130_;
																									loc_1130_ = bit32_or(loc_1132_ + -4, 0);
																									loc_1123_ = buffer_read_i32(loc_1081_[1], loc_1130_, 0);
																									if rt_equal_i32(loc_1123_, 0) then
																										loc_1119_ = 1;
																										loc_1122_ = 65535;
																									else
																										loc_1119_ = 0;
																										loc_1122_ = 0;
																									end
																								end
																								loc_1123_ = loc_1119_;
																							until loc_1119_ == 0
																							if rt_not_equal_i32(loc_1122_, 0) then
																							end
																							loc_1130_ = buffer_read_i32(loc_1081_[1], loc_1082_, 92);
																							loc_1119_ = bit32_or(loc_1130_ - loc_1128_, 0);
																							rt_store_i32(loc_1081_, loc_1082_, 92, loc_1119_)
																							loc_1128_ = loc_1132_;
																							loc_1130_ = loc_1119_;
																						until not (rt_greater_than_s32(loc_1119_, 0))
																					else
																						loc_1128_ = loc_1132_;
																						loc_1118_ = loc_1111_;
																					end
																					if not (rt_greater_than_s32(loc_1130_, -1)) then
																						loc_1119_ = loc_1129_;
																						loc_1132_ = loc_1131_;
																						loc_1131_ = loc_1132_;
																						loc_1129_ = loc_1119_;
																						loc_1117_ = rt_divide_u32(bit32_or(loc_1132_ + 25, 0), 9);
																						loc_1132_ = bit32_or(loc_1117_ + 1, 0);
																						loc_1119_ = (rt_equal_i32(loc_1119_, 102) and 1 or 0);
																						repeat
																							rt_yield_budget = rt_yield_budget - 1
																							if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																							loc_1121_ = bit32_or(0 - loc_1130_, 0);
																							loc_1130_ = 9;
																							if rt_less_than_u32(loc_1121_, 9) then
																								loc_1115_ = loc_1111_;
																								loc_1116_, loc_1121_ = loc_1121_, loc_1116_;
																								loc_1118_, loc_1130_ = loc_1130_, loc_1118_;
																								loc_1130_, loc_1128_ = loc_1128_, loc_1130_;
																							else
																								loc_1115_ = loc_1111_;
																								loc_1117_ = loc_1121_;
																								loc_1121_ = loc_1116_;
																								loc_1118_, loc_1130_ = loc_1130_, loc_1118_;
																								loc_1130_, loc_1128_ = loc_1128_, loc_1130_;
																								loc_1116_ = loc_1118_;
																							end
																							if rt_less_than_u32(loc_1128_, loc_1130_) then
																								loc_1118_ = loc_1128_;
																								loc_1117_ = 0;
																								loc_1121_ = loc_1116_;
																								loc_1114_ = rt_exclusive_or_i32(rt_shift_left_i32(-1, loc_1116_), -1);
																								loc_1116_ = rt_shift_right_u32(1000000000, loc_1116_);
																								repeat
																									rt_yield_budget = rt_yield_budget - 1
																									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																									loc_1110_ = loc_1130_;
																									loc_1130_ = loc_1117_;
																									loc_1117_ = buffer_read_i32(loc_1081_[1], loc_1118_, 0);
																									rt_store_i32(loc_1081_, loc_1118_, 0, bit32_or(rt_shift_right_u32(loc_1117_, loc_1121_) + loc_1130_, 0))
																									loc_1130_ = loc_1110_;
																									loc_1111_ = bit32_or(loc_1118_ + 4, 0);
																									loc_1118_ = loc_1111_;
																									loc_1117_ = rt_multiply_i32(rt_and_i32(loc_1117_, loc_1114_), loc_1116_);
																								until not (rt_less_than_u32(loc_1111_, loc_1110_))
																								loc_1111_ = buffer_read_i32(loc_1081_[1], loc_1128_, 0);
																								loc_1118_ = 0;
																								loc_1114_ = 4;
																								if not (rt_not_equal_i32(loc_1111_, 0)) then
																									loc_1118_ = loc_1114_;
																								end
																								if not (rt_equal_i32(loc_1117_, 0)) then
																									rt_store_i32(loc_1081_, loc_1130_, 0, loc_1117_)
																									loc_1130_ = bit32_or(loc_1130_ + 4, 0);
																								end
																							else
																								loc_1114_ = buffer_read_i32(loc_1081_[1], loc_1128_, 0);
																								loc_1118_ = 0;
																								loc_1117_ = 4;
																								if rt_not_equal_i32(loc_1114_, 0) then
																									loc_1116_, loc_1121_ = loc_1121_, loc_1116_;
																								else
																									loc_1116_, loc_1121_ = loc_1121_, loc_1116_;
																									loc_1118_ = loc_1117_;
																								end
																							end
																							loc_1117_ = buffer_read_i32(loc_1081_[1], loc_1082_, 92);
																							loc_1117_ = bit32_or(loc_1117_ + loc_1121_, 0);
																							rt_store_i32(loc_1081_, loc_1082_, 92, loc_1117_)
																							loc_1128_ = bit32_or(loc_1128_ + loc_1118_, 0);
																							if rt_not_equal_i32(loc_1119_, 0) then
																								loc_1111_ = loc_1115_;
																								loc_1118_ = loc_1128_;
																							else
																								loc_1111_ = loc_1115_;
																								loc_1118_ = loc_1128_;
																								loc_1115_ = loc_1128_;
																							end
																							loc_1128_ = bit32_or(loc_1115_ + rt_shift_left_i32(loc_1132_, 2), 0);
																							if not (rt_greater_than_s32(rt_shift_right_s32(bit32_or(loc_1130_ - loc_1115_, 0), 2), loc_1132_)) then
																								loc_1128_ = loc_1130_;
																							end
																							loc_1130_ = loc_1117_;
																						until not (rt_less_than_s32(loc_1117_, 0))
																					end
																					loc_1119_ = 0;
																					if not (rt_greater_than_equal_u32(loc_1118_, loc_1128_)) then
																						loc_1132_ = loc_1130_;
																						loc_1130_ = loc_1119_;
																						loc_1130_ = buffer_read_i32(loc_1081_[1], loc_1118_, 0);
																						loc_1119_ = rt_multiply_i32(rt_shift_right_s32(bit32_or(loc_1111_ - loc_1118_, 0), 2), 9);
																						if not (rt_less_than_u32(loc_1130_, 10)) then
																							loc_1132_ = 10;
																							repeat
																								rt_yield_budget = rt_yield_budget - 1
																								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																								loc_1115_ = loc_1130_;
																								loc_1117_ = rt_multiply_i32(loc_1132_, 10);
																								loc_1132_ = loc_1117_;
																								loc_1130_ = loc_1115_;
																								loc_1119_ = bit32_or(loc_1119_ + 1, 0);
																							until not (rt_greater_than_equal_u32(loc_1115_, loc_1117_))
																						end
																					end
																					loc_1132_ = 0;
																					if rt_equal_i32(loc_1129_, 102) then
																						loc_1114_ = loc_1131_;
																						loc_1117_ = loc_1119_;
																					else
																						loc_1114_ = loc_1131_;
																						loc_1117_ = loc_1119_;
																						loc_1132_ = loc_1119_;
																					end
																					loc_1110_ = (rt_equal_i32(loc_1129_, 103) and 1 or 0);
																					loc_1129_ = bit32_or(bit32_or(loc_1131_ - loc_1132_, 0) - rt_and_i32((rt_not_equal_i32(loc_1114_, 0) and 1 or 0), loc_1110_), 0);
																					if not (rt_greater_than_equal_s32(loc_1129_, bit32_or(rt_multiply_i32(rt_shift_right_s32(bit32_or(loc_1128_ - loc_1111_, 0), 2), 9) + -9, 0))) then
																						loc_1131_ = loc_1130_;
																						loc_1130_ = loc_1121_;
																						loc_1132_ = loc_1125_;
																						loc_1125_ = loc_1116_;
																						loc_1130_ = bit32_or(loc_1082_ + 96, 0);
																						loc_1125_ = -4092;
																						loc_1131_ = -3804;
																						if rt_not_equal_i32(loc_1132_, 0) then
																							loc_1132_ = loc_1129_;
																							loc_1129_ = loc_1128_;
																						else
																							loc_1132_ = loc_1129_;
																							loc_1129_ = loc_1128_;
																							loc_1128_ = loc_1125_;
																							loc_1125_ = loc_1131_;
																						end
																						loc_1128_ = 10;
																						loc_1132_ = bit32_or(loc_1132_ + 9216, 0);
																						loc_1131_ = rt_divide_s32(loc_1132_, 9);
																						loc_1132_ = bit32_or(loc_1132_ - rt_multiply_i32(loc_1131_, 9), 0);
																						loc_1119_ = rt_shift_left_i32(loc_1131_, 2);
																						loc_1116_ = bit32_or(bit32_or(loc_1130_ + loc_1125_, 0) + loc_1119_, 0);
																						if not (rt_greater_than_s32(loc_1132_, 7)) then
																							loc_1130_ = loc_1132_;
																							loc_1132_ = loc_1128_;
																							loc_1128_ = 10;
																							loc_1131_ = bit32_or(8 - loc_1130_, 0);
																							loc_1132_ = rt_and_i32(loc_1131_, 7);
																							if not (rt_less_than_u32(bit32_or(loc_1130_ + -1, 0), 7)) then
																								loc_1130_ = loc_1128_;
																								loc_1128_ = 10;
																								loc_1131_ = rt_and_i32(loc_1131_, -8);
																								repeat
																									rt_yield_budget = rt_yield_budget - 1
																									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																									loc_1128_ = rt_multiply_i32(loc_1128_, 100000000);
																									loc_1130_ = bit32_or(loc_1131_ + -8, 0);
																									loc_1131_ = loc_1130_;
																								until loc_1130_ == 0
																							end
																							if not (rt_equal_i32(loc_1132_, 0)) then
																								repeat
																									rt_yield_budget = rt_yield_budget - 1
																									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																									loc_1128_ = rt_multiply_i32(loc_1128_, 10);
																									loc_1131_ = bit32_or(loc_1132_ + -1, 0);
																									loc_1132_ = loc_1131_;
																								until loc_1131_ == 0
																							end
																						end
																						loc_1130_ = buffer_read_i32(loc_1081_[1], loc_1116_, 0);
																						loc_1108_ = rt_divide_u32(loc_1130_, loc_1128_);
																						loc_1121_ = bit32_or(loc_1130_ - rt_multiply_i32(loc_1108_, loc_1128_), 0);
																						loc_1115_ = bit32_or(loc_1116_ + 4, 0);
																						loc_1132_ = loc_1108_;
																						if rt_not_equal_i32(loc_1121_, 0) then
																							loc_1132_ = 0;
																						else
																							if rt_equal_i32(loc_1115_, loc_1129_) then
																								loc_1132_ = 1;
																							else
																								loc_1132_ = 0;
																							end
																						end
																						if not (rt_not_equal_i32(loc_1132_, 0)) then
																							if rt_not_equal_i32(rt_and_i32(loc_1108_, 1), 0) then
																								loc_1131_ = loc_1115_;
																								loc_1115_ = loc_1126_;
																								loc_1126_ = loc_1125_;
																								loc_1125_ = loc_1119_;
																								loc_1132_ = 0;
																							else
																								loc_1131_ = loc_1115_;
																								loc_1132_ = loc_1126_;
																								loc_1126_ = loc_1125_;
																								loc_1125_ = loc_1119_;
																								loc_1115_ = from_bits_f64(0, 1128267776) --[[ 9007199254740992_f64 ]];
																								if rt_not_equal_i32(loc_1128_, 1000000000) then
																									loc_1132_ = 1;
																								else
																									if rt_less_than_equal_u32(loc_1116_, loc_1118_) then
																										loc_1132_ = 1;
																									else
																										loc_1132_ = rt_load_i32_from_u8(loc_1081_, bit32_or(loc_1116_ + -4, 0), 0);
																										if rt_equal_i32(rt_and_i32(loc_1132_, 1), 0) then
																											loc_1132_ = 1;
																										else
																											loc_1132_ = 0;
																										end
																									end
																								end
																							end
																							if not (rt_not_equal_i32(loc_1132_, 0)) then
																								loc_1132_ = loc_1115_;
																								loc_1115_ = from_bits_f64(1, 1128267776) --[[ 9007199254740994_f64 ]];
																							end
																							loc_1119_ = from_bits_f64(0, 1071644672) --[[ 0.5_f64 ]];
																							loc_1108_ = from_bits_f64(0, 1072693248) --[[ 1_f64 ]];
																							loc_1132_ = from_bits_f64(0, 1073217536) --[[ 1.5_f64 ]];
																							if not (rt_equal_i32(loc_1131_, loc_1129_)) then
																								loc_1131_ = loc_1108_;
																								loc_1108_ = loc_1132_;
																							end
																							loc_1131_ = rt_shift_right_u32(loc_1128_, 1);
																							loc_1132_ = from_bits_f64(0, 1073217536) --[[ 1.5_f64 ]];
																							if not (rt_equal_i32(loc_1121_, loc_1131_)) then
																								loc_1108_ = loc_1132_;
																							end
																							if not (rt_less_than_u32(loc_1121_, loc_1131_)) then
																								loc_1119_ = loc_1108_;
																							end
																							if not (rt_not_equal_i32(loc_1090_, 0)) then
																								loc_1108_ = rt_load_i32_from_u8(loc_1081_, loc_1124_, 0);
																								if not (rt_not_equal_i32(loc_1108_, 45)) then
																									loc_1115_ = rt_negate_f64(loc_1115_);
																									loc_1119_ = rt_negate_f64(loc_1119_);
																								end
																							end
																							loc_1130_ = bit32_or(loc_1130_ - loc_1121_, 0);
																							rt_store_i32(loc_1081_, loc_1116_, 0, loc_1130_)
																							if not (rt_equal_f64(rt_add_f64(loc_1115_, loc_1119_), loc_1115_)) then
																								loc_1119_ = loc_1117_;
																								loc_1130_ = bit32_or(loc_1130_ + loc_1128_, 0);
																								rt_store_i32(loc_1081_, loc_1116_, 0, loc_1130_)
																								if rt_less_than_u32(loc_1130_, 1000000000) then
																									loc_1128_ = loc_1125_;
																									loc_1130_ = loc_1126_;
																								else
																									loc_1128_ = loc_1125_;
																									loc_1125_ = loc_1116_;
																									loc_1130_ = loc_1126_;
																									loc_1126_ = loc_1099_;
																									loc_1099_ = loc_1126_;
																									loc_1130_ = bit32_or(loc_1126_ + bit32_or(loc_1130_ + loc_1128_, 0), 0);
																									repeat
																										rt_yield_budget = rt_yield_budget - 1
																										if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																										rt_store_i32(loc_1081_, bit32_or(loc_1130_ + 4, 0), 0, 0)
																										if not (rt_greater_than_equal_u32(loc_1130_, loc_1118_)) then
																											loc_1118_ = bit32_or(loc_1118_ + -4, 0);
																											rt_store_i32(loc_1081_, loc_1118_, 0, 0)
																										end
																										loc_1128_ = buffer_read_i32(loc_1081_[1], loc_1130_, 0);
																										loc_1128_ = bit32_or(loc_1128_ + 1, 0);
																										rt_store_i32(loc_1081_, loc_1130_, 0, loc_1128_)
																										loc_1130_ = bit32_or(loc_1130_ + -4, 0);
																									until not (rt_greater_than_u32(loc_1128_, 999999999))
																									loc_1116_ = bit32_or(loc_1130_ + 4, 0);
																								end
																								loc_1130_ = buffer_read_i32(loc_1081_[1], loc_1118_, 0);
																								loc_1117_ = rt_multiply_i32(rt_shift_right_s32(bit32_or(loc_1111_ - loc_1118_, 0), 2), 9);
																								if not (rt_less_than_u32(loc_1130_, 10)) then
																									loc_1128_ = 10;
																									repeat
																										rt_yield_budget = rt_yield_budget - 1
																										if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																										loc_1125_ = loc_1130_;
																										loc_1126_ = rt_multiply_i32(loc_1128_, 10);
																										loc_1128_ = loc_1126_;
																										loc_1130_ = loc_1125_;
																										loc_1117_ = bit32_or(loc_1117_ + 1, 0);
																									until not (rt_greater_than_equal_u32(loc_1125_, loc_1126_))
																								end
																							end
																						end
																						loc_1128_ = bit32_or(loc_1116_ + 4, 0);
																						if not (rt_greater_than_u32(loc_1129_, loc_1128_)) then
																							loc_1128_ = loc_1129_;
																						end
																					end
																					loc_1129_ = loc_1128_;
																					loc_1128_ = bit32_or(loc_1128_ - loc_1111_, 0);
																					repeat
																						rt_yield_budget = rt_yield_budget - 1
																						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																						loc_1125_ = loc_1130_;
																						loc_1126_ = loc_1122_;
																						loc_1122_ = loc_1116_;
																						loc_1130_ = loc_1123_;
																						loc_1123_ = loc_1121_;
																						loc_1121_ = (rt_less_than_equal_u32(loc_1129_, loc_1118_) and 1 or 0);
																						if rt_not_equal_i32(loc_1121_, 0) then
																							loc_1116_ = loc_1129_;
																							loc_1130_ = loc_1128_;
																							loc_1126_ = 0;
																							loc_1122_ = 1;
																						else
																							loc_1116_ = loc_1129_;
																							loc_1130_ = loc_1128_;
																							loc_1129_ = bit32_or(loc_1116_ + -4, 0);
																							loc_1126_ = buffer_read_i32(loc_1081_[1], loc_1129_, 0);
																							loc_1128_ = bit32_or(loc_1130_ + -4, 0);
																							if rt_equal_i32(loc_1126_, 0) then
																								loc_1126_ = 1;
																								loc_1122_ = 65535;
																							else
																								loc_1126_ = 0;
																								loc_1122_ = 0;
																							end
																						end
																						loc_1123_ = loc_1126_;
																					until loc_1126_ == 0
																					if rt_not_equal_i32(loc_1122_, 0) then
																					end
																					if rt_not_equal_i32(loc_1110_, 0) then
																						loc_1129_ = rt_exclusive_or_i32(loc_1117_, -1);
																						loc_1128_ = -1;
																						loc_1126_ = 1;
																						if not (rt_not_equal_i32(loc_1114_, 0)) then
																							loc_1125_ = loc_1114_;
																							loc_1114_ = loc_1126_;
																						end
																						loc_1119_ = rt_and_i32((rt_greater_than_s32(loc_1114_, loc_1117_) and 1 or 0), (rt_greater_than_s32(loc_1117_, -5) and 1 or 0));
																						if not (rt_not_equal_i32(loc_1119_, 0)) then
																							loc_1129_ = loc_1128_;
																						end
																						loc_1129_ = bit32_or(loc_1129_ + loc_1114_, 0);
																						loc_1128_ = -1;
																						loc_1126_ = -2;
																						if not (rt_not_equal_i32(loc_1119_, 0)) then
																							loc_1128_ = loc_1126_;
																						end
																						loc_1115_ = bit32_or(loc_1128_ + loc_1127_, 0);
																						loc_1126_ = rt_and_i32(loc_1120_, 8);
																						if not (rt_not_equal_i32(loc_1126_, 0)) then
																							loc_1127_ = loc_1119_;
																							loc_1128_ = loc_1130_;
																							loc_1130_ = loc_1114_;
																							loc_1130_ = -9;
																							if not (rt_not_equal_i32(loc_1121_, 0)) then
																								loc_1127_ = loc_1121_;
																								loc_1121_ = buffer_read_i32(loc_1081_[1], bit32_or(loc_1116_ + -4, 0), 0);
																								if not (rt_equal_i32(loc_1121_, 0)) then
																									loc_1130_ = 0;
																									loc_1127_ = rt_remainder_u32(loc_1121_, 10);
																									loc_1126_ = loc_1127_;
																									if not (rt_not_equal_i32(loc_1127_, 0)) then
																										loc_1130_ = 0;
																										loc_1127_ = 10;
																										repeat
																											rt_yield_budget = rt_yield_budget - 1
																											if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																											loc_1125_ = loc_1121_;
																											loc_1130_ = bit32_or(loc_1130_ + -1, 0);
																											loc_1126_ = rt_multiply_i32(loc_1127_, 10);
																											loc_1127_ = loc_1126_;
																											loc_1121_ = loc_1125_;
																											loc_1126_ = rt_remainder_u32(loc_1125_, loc_1126_);
																											loc_1125_ = loc_1126_;
																										until not (rt_equal_i32(loc_1126_, 0))
																									end
																								end
																							end
																							loc_1119_ = rt_multiply_i32(rt_shift_right_s32(loc_1128_, 2), 9);
																							if rt_not_equal_i32(rt_and_i32(loc_1115_, -33), 70) then
																								loc_1126_ = 0;
																								loc_1130_ = bit32_or(bit32_or(bit32_or(loc_1117_ + loc_1119_, 0) + loc_1130_, 0) + -9, 0);
																								loc_1127_ = 0;
																								if rt_greater_than_s32(loc_1130_, 0) then
																									loc_1128_ = loc_1129_;
																								else
																									loc_1128_ = loc_1129_;
																									loc_1130_ = loc_1127_;
																								end
																								if rt_less_than_s32(loc_1128_, loc_1130_) then
																									loc_1114_ = loc_1130_;
																								else
																									loc_1114_ = loc_1130_;
																									loc_1129_ = loc_1130_;
																								end
																							else
																								loc_1126_ = 0;
																								loc_1130_ = bit32_or(bit32_or(loc_1119_ + loc_1130_, 0) + -9, 0);
																								loc_1127_ = 0;
																								if rt_greater_than_s32(loc_1130_, 0) then
																									loc_1128_ = loc_1129_;
																								else
																									loc_1128_ = loc_1129_;
																									loc_1130_ = loc_1127_;
																								end
																								if rt_less_than_s32(loc_1128_, loc_1130_) then
																									loc_1114_ = loc_1130_;
																								else
																									loc_1114_ = loc_1130_;
																									loc_1129_ = loc_1130_;
																								end
																							end
																						end
																					else
																						loc_1125_ = loc_1130_;
																						loc_1126_ = loc_1129_;
																						loc_1129_ = loc_1114_;
																						loc_1130_ = loc_1120_;
																						loc_1114_ = loc_1126_;
																						loc_1119_ = loc_1128_;
																						loc_1120_ = loc_1130_;
																						loc_1115_ = loc_1127_;
																						loc_1126_ = rt_and_i32(loc_1130_, 8);
																					end
																					loc_1125_ = rt_or_i32(loc_1129_, loc_1126_);
																					loc_1130_ = 2147483645;
																					loc_1128_ = 2147483646;
																					if rt_not_equal_i32(loc_1125_, 0) then
																						loc_1108_ = loc_1129_;
																					else
																						loc_1108_ = loc_1129_;
																						loc_1130_ = loc_1128_;
																					end
																					if rt_greater_than_s32(loc_1129_, loc_1130_) then
																						loc_1122_ = 4;
																						loc_1115_ = 0;
																						loc_1096_ = 16;
																					else
																						loc_1130_ = (rt_not_equal_i32(rt_and_i32(loc_1115_, -33), 70) and 1 or 0);
																						loc_1127_ = bit32_or(bit32_or(loc_1108_ + (rt_not_equal_i32(loc_1125_, 0) and 1 or 0), 0) + 1, 0);
																						if rt_not_equal_i32(loc_1130_, 0) then
																							loc_1128_ = loc_1123_;
																							loc_1123_ = loc_1125_;
																							loc_1125_ = loc_1098_;
																							loc_1129_ = loc_1115_;
																							loc_1115_ = loc_1122_;
																							loc_1122_ = loc_1130_;
																							loc_1130_ = loc_1114_;
																							loc_1114_ = loc_1090_;
																							loc_1090_ = loc_1126_;
																							loc_1126_ = loc_1096_;
																							if rt_not_equal_i32(loc_1117_, 0) then
																								loc_1098_ = loc_1125_;
																								loc_1130_ = rt_shift_right_s32(loc_1117_, 31);
																								loc_1114_ = bit32_or(rt_exclusive_or_i32(loc_1117_, loc_1130_) - loc_1130_, 0);
																								loc_1119_ = loc_1125_;
																								repeat
																									rt_yield_budget = rt_yield_budget - 1
																									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																									loc_1130_ = loc_1121_;
																									loc_1121_ = loc_1110_;
																									loc_1110_ = loc_1114_;
																									loc_1119_ = bit32_or(loc_1119_ + -1, 0);
																									loc_1130_ = rt_divide_u32(loc_1110_, 10);
																									rt_store_i32_into_i8(loc_1081_, loc_1119_, 0, rt_or_i32(bit32_or(loc_1110_ - rt_multiply_i32(loc_1130_, 10), 0), 48))
																									loc_1114_ = loc_1130_;
																									loc_1125_ = bit32_or(loc_1125_ + -1, 0);
																									loc_1121_ = loc_1130_;
																									loc_1096_ = (rt_greater_than_u32(loc_1110_, 9) and 1 or 0);
																									loc_1110_ = loc_1096_;
																								until loc_1096_ == 0
																							else
																								loc_1098_ = loc_1125_;
																								loc_1119_ = loc_1125_;
																							end
																							if not (rt_greater_than_s32(bit32_or(loc_1098_ - loc_1125_, 0), 1)) then
																								loc_1114_ = loc_1125_;
																								loc_1125_ = bit32_or(bit32_or(loc_1114_ - bit32_or(loc_1082_ + 52, 0), 0) + -10, 0);
																								loc_1119_ = bit32_or(loc_1119_ + bit32_or(loc_1106_ - loc_1114_, 0), 0);
																								if not (rt_equal_i32(loc_1125_, 0)) then
																									rt_memory_fill(loc_1081_, loc_1119_, 48, loc_1125_)
																								end
																							end
																							loc_1125_ = bit32_or(loc_1119_ + -2, 0);
																							rt_store_i32_into_i8(loc_1081_, loc_1125_, 0, loc_1129_)
																							loc_1096_ = bit32_or(loc_1119_ + -1, 0);
																							loc_1114_ = 45;
																							loc_1129_ = 43;
																							if not (rt_less_than_s32(loc_1117_, 0)) then
																								loc_1114_ = loc_1129_;
																							end
																							rt_store_i32_into_i8(loc_1081_, loc_1096_, 0, loc_1114_)
																							loc_1114_ = bit32_or(loc_1098_ - loc_1125_, 0);
																							if rt_greater_than_s32(loc_1114_, rt_exclusive_or_i32(loc_1127_, 2147483647)) then
																								loc_1128_ = 2;
																								loc_1115_ = 0;
																								loc_1096_ = 18;
																							else
																								loc_1096_ = loc_1115_;
																								loc_1115_ = loc_1128_;
																								loc_1128_ = 0;
																							end
																						else
																							loc_1128_ = loc_1123_;
																							loc_1123_ = loc_1125_;
																							loc_1125_ = loc_1098_;
																							loc_1129_ = loc_1115_;
																							loc_1115_ = loc_1122_;
																							loc_1122_ = loc_1130_;
																							loc_1130_ = loc_1114_;
																							loc_1114_ = loc_1090_;
																							loc_1090_ = loc_1126_;
																							loc_1126_ = loc_1096_;
																							if rt_greater_than_s32(loc_1117_, rt_exclusive_or_i32(loc_1127_, 2147483647)) then
																								loc_1098_ = loc_1125_;
																								loc_1125_ = loc_1114_;
																								loc_1114_ = loc_1130_;
																								loc_1129_ = loc_1115_;
																								loc_1130_ = loc_1128_;
																								loc_1128_ = 1;
																								loc_1115_ = 0;
																								loc_1096_ = 17;
																							else
																								loc_1098_ = loc_1125_;
																								loc_1125_ = loc_1114_;
																								loc_1129_ = loc_1115_;
																								loc_1128_, loc_1130_ = loc_1130_, loc_1128_;
																								loc_1128_ = 0;
																								if rt_greater_than_s32(loc_1117_, 0) then
																									loc_1096_ = loc_1129_;
																									loc_1114_ = loc_1117_;
																									loc_1115_ = loc_1130_;
																									loc_1130_ = loc_1128_;
																								else
																									loc_1096_ = loc_1129_;
																									loc_1115_ = loc_1130_;
																									loc_1129_ = loc_1117_;
																									loc_1130_ = loc_1128_;
																									loc_1114_ = loc_1130_;
																								end
																								loc_1128_ = 0;
																							end
																						end
																						if (loc_1128_) >= 0 and (loc_1128_) < 2 then
																							if (loc_1128_) < 1 then
																								loc_1114_ = bit32_or(loc_1114_ + loc_1127_, 0);
																								if rt_greater_than_s32(loc_1114_, rt_exclusive_or_i32(loc_1126_, 2147483647)) then
																									loc_1115_ = loc_1090_;
																									loc_1127_ = loc_1096_;
																									loc_1122_ = 4;
																									loc_1115_ = 0;
																									loc_1096_ = 19;
																								else
																									loc_1115_ = loc_1090_;
																									loc_1127_ = loc_1096_;
																									loc_1110_ = bit32_or(loc_1114_ + loc_1126_, 0);
																									loc_1120_ = rt_and_i32(loc_1120_, 73728);
																									if rt_not_equal_i32(loc_1120_, 0) then
																										loc_1096_ = loc_1124_;
																										loc_1124_ = loc_1127_;
																										loc_1127_ = loc_1110_;
																										loc_1110_ = loc_1122_;
																										loc_1122_ = loc_1114_;
																										loc_1114_ = loc_1109_;
																										loc_1109_ = loc_1126_;
																										loc_1126_ = loc_1125_;
																										loc_1125_ = loc_1078_;
																										loc_1115_, loc_1123_ = loc_1123_, loc_1115_;
																									else
																										loc_1096_ = loc_1124_;
																										loc_1124_ = loc_1127_;
																										loc_1127_ = loc_1110_;
																										loc_1110_ = loc_1122_;
																										loc_1122_ = loc_1114_;
																										loc_1114_ = loc_1109_;
																										loc_1109_ = loc_1126_;
																										loc_1126_ = loc_1125_;
																										loc_1125_ = loc_1078_;
																										loc_1115_, loc_1123_ = loc_1123_, loc_1115_;
																										if not (rt_less_than_equal_s32(loc_1114_, loc_1127_)) then
																											loc_1090_ = bit32_or(loc_1114_ - loc_1127_, 0);
																											loc_1119_ = (rt_less_than_u32(loc_1090_, 256) and 1 or 0);
																											loc_1078_ = 256;
																											if rt_not_equal_i32(loc_1119_, 0) then
																												loc_1122_ = loc_1090_;
																											else
																												loc_1122_ = loc_1090_;
																												loc_1090_ = loc_1078_;
																											end
																											if not (rt_equal_i32(loc_1090_, 0)) then
																												rt_memory_fill(loc_1081_, bit32_or(loc_1082_ + 608, 0), 32, loc_1090_)
																											end
																											if not (rt_not_equal_i32(loc_1119_, 0)) then
																												repeat
																													rt_yield_budget = rt_yield_budget - 1
																													if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																													loc_1090_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																													if not (rt_not_equal_i32(rt_and_i32(loc_1090_, 32), 0)) then
																														loc_1090_ = __spider_scoped_dependencies[1];
																														__spider_scoped_dependencies[1] = loc_1090_;
																														loc_1090_ = loc_1090_[1](bit32_or(loc_1082_ + 608, 0), 256, loc_1091_, loc_1125_)
																													end
																													loc_1090_ = bit32_or(loc_1122_ + -256, 0);
																													loc_1122_ = loc_1090_;
																												until not (rt_greater_than_u32(loc_1090_, 255))
																											end
																											loc_1090_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																											if not (rt_not_equal_i32(rt_and_i32(loc_1090_, 32), 0)) then
																												loc_1090_ = __spider_scoped_dependencies[1];
																												__spider_scoped_dependencies[1] = loc_1090_;
																												loc_1090_ = loc_1090_[1](bit32_or(loc_1082_ + 608, 0), loc_1122_, loc_1091_, loc_1125_)
																											end
																										end
																									end
																									loc_1090_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																									if not (rt_not_equal_i32(rt_and_i32(loc_1090_, 32), 0)) then
																										loc_1090_ = __spider_scoped_dependencies[1];
																										__spider_scoped_dependencies[1] = loc_1090_;
																										loc_1109_ = loc_1090_[1](loc_1096_, loc_1109_, loc_1091_, loc_1125_)
																									end
																									if not (rt_not_equal_i32(loc_1120_, 65536)) then
																										if not (rt_less_than_equal_s32(loc_1114_, loc_1127_)) then
																											loc_1109_ = bit32_or(loc_1114_ - loc_1127_, 0);
																											loc_1119_ = (rt_less_than_u32(loc_1109_, 256) and 1 or 0);
																											loc_1096_ = 256;
																											if rt_not_equal_i32(loc_1119_, 0) then
																												loc_1122_ = loc_1109_;
																											else
																												loc_1122_ = loc_1109_;
																												loc_1109_ = loc_1096_;
																											end
																											if not (rt_equal_i32(loc_1109_, 0)) then
																												rt_memory_fill(loc_1081_, bit32_or(loc_1082_ + 608, 0), 48, loc_1109_)
																											end
																											if not (rt_not_equal_i32(loc_1119_, 0)) then
																												repeat
																													rt_yield_budget = rt_yield_budget - 1
																													if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																													loc_1109_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																													if not (rt_not_equal_i32(rt_and_i32(loc_1109_, 32), 0)) then
																														loc_1109_ = __spider_scoped_dependencies[1];
																														__spider_scoped_dependencies[1] = loc_1109_;
																														loc_1109_ = loc_1109_[1](bit32_or(loc_1082_ + 608, 0), 256, loc_1091_, loc_1125_)
																													end
																													loc_1109_ = bit32_or(loc_1122_ + -256, 0);
																													loc_1122_ = loc_1109_;
																												until not (rt_greater_than_u32(loc_1109_, 255))
																											end
																											loc_1109_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																											if not (rt_not_equal_i32(rt_and_i32(loc_1109_, 32), 0)) then
																												loc_1109_ = __spider_scoped_dependencies[1];
																												__spider_scoped_dependencies[1] = loc_1109_;
																												loc_1109_ = loc_1109_[1](bit32_or(loc_1082_ + 608, 0), loc_1122_, loc_1091_, loc_1125_)
																											end
																										end
																									end
																									if rt_not_equal_i32(loc_1110_, 0) then
																										if not (rt_less_than_s32(loc_1108_, 0)) then
																											loc_1122_ = loc_1121_;
																											loc_1122_ = bit32_or(loc_1118_ + 4, 0);
																											if rt_greater_than_u32(loc_1116_, loc_1118_) then
																												loc_1121_ = loc_1118_;
																											else
																												loc_1121_ = loc_1118_;
																												loc_1118_ = loc_1116_;
																												loc_1116_ = loc_1122_;
																											end
																											loc_1118_ = loc_1121_;
																											repeat
																												rt_yield_budget = rt_yield_budget - 1
																												if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																												loc_1122_ = loc_1119_;
																												loc_1119_ = buffer_read_i32(loc_1081_[1], loc_1121_, 0);
																												if rt_equal_i32(loc_1119_, 0) then
																													loc_1122_ = loc_1108_;
																													loc_1124_ = loc_1121_;
																													loc_1121_ = loc_1104_;
																													rt_store_i32_into_i8(loc_1081_, loc_1082_, 72, 48)
																													loc_1104_ = loc_1121_;
																												else
																													loc_1115_ = loc_1104_;
																													loc_1122_ = loc_1108_;
																													loc_1124_ = loc_1121_;
																													loc_1121_ = loc_1105_;
																													loc_1104_ = loc_1115_;
																													loc_1105_ = loc_1121_;
																													repeat
																														rt_yield_budget = rt_yield_budget - 1
																														if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																														loc_1117_, loc_1119_ = loc_1119_, loc_1117_;
																														loc_1121_ = bit32_or(loc_1121_ + -1, 0);
																														loc_1110_ = rt_divide_u32(loc_1117_, 10);
																														rt_store_i32_into_i8(loc_1081_, loc_1121_, 0, rt_or_i32(bit32_or(loc_1117_ - rt_multiply_i32(loc_1110_, 10), 0), 48))
																														loc_1119_ = loc_1110_;
																														loc_1115_ = (rt_less_than_u32(loc_1117_, 10) and 1 or 0);
																														loc_1117_ = loc_1115_;
																													until not (rt_equal_i32(loc_1115_, 0))
																												end
																												if rt_equal_i32(loc_1124_, loc_1118_) then
																													loc_1119_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																													if not (rt_not_equal_i32(rt_and_i32(loc_1119_, 32), 0)) then
																														loc_1119_ = __spider_scoped_dependencies[1];
																														__spider_scoped_dependencies[1] = loc_1119_;
																														loc_1119_ = loc_1119_[1](loc_1121_, 1, loc_1091_, loc_1125_)
																													end
																													loc_1119_ = bit32_or(loc_1121_ + 1, 0);
																													if not (rt_equal_i32(rt_or_i32(loc_1122_, loc_1123_), 0)) then
																														loc_1121_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																														if not (rt_not_equal_i32(rt_and_i32(loc_1121_, 32), 0)) then
																															loc_1121_ = __spider_scoped_dependencies[1];
																															__spider_scoped_dependencies[1] = loc_1121_;
																															loc_1121_ = loc_1121_[1](1106, 1, loc_1091_, loc_1125_)
																														end
																													end
																												else
																													if rt_less_than_equal_u32(loc_1121_, bit32_or(loc_1082_ + 64, 0)) then
																														loc_1119_ = loc_1121_;
																													else
																														loc_1119_ = loc_1121_;
																														loc_1119_ = bit32_or(loc_1119_ - bit32_or(loc_1082_ + 64, 0), 0);
																														if rt_equal_i32(loc_1119_, 0) then
																															loc_1121_ = loc_1082_;
																														else
																															loc_1121_ = loc_1082_;
																															rt_memory_fill(loc_1081_, bit32_or(loc_1121_ + 64, 0), 48, loc_1119_)
																														end
																														loc_1082_ = loc_1121_;
																														loc_1119_ = bit32_or(loc_1121_ + 64, 0);
																													end
																												end
																												loc_1115_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																												loc_1121_ = bit32_or(loc_1105_ - loc_1119_, 0);
																												if not (rt_not_equal_i32(rt_and_i32(loc_1115_, 32), 0)) then
																													if rt_less_than_s32(loc_1121_, loc_1122_) then
																														loc_1108_ = loc_1122_;
																														loc_1109_ = __spider_scoped_dependencies[1];
																														loc_1110_ = loc_1119_;
																														loc_1115_ = loc_1121_;
																													else
																														loc_1108_ = loc_1122_;
																														loc_1109_ = __spider_scoped_dependencies[1];
																														loc_1110_ = loc_1119_;
																														loc_1115_ = loc_1121_;
																														loc_1115_ = loc_1108_;
																													end
																													__spider_scoped_dependencies[1] = loc_1109_;
																													loc_1115_ = loc_1109_[1](loc_1110_, loc_1115_, loc_1091_, loc_1125_)
																												end
																												loc_1108_ = bit32_or(loc_1122_ - loc_1121_, 0);
																												loc_1121_ = bit32_or(loc_1124_ + 4, 0);
																												if rt_greater_than_equal_u32(loc_1121_, loc_1116_) then
																													loc_1122_ = 0;
																													loc_1124_ = 1;
																												else
																													if rt_greater_than_s32(loc_1108_, -1) then
																														loc_1122_ = 1;
																														loc_1124_ = 65535;
																													else
																														loc_1122_ = 0;
																														loc_1124_ = 0;
																													end
																												end
																											until loc_1122_ == 0
																											if rt_not_equal_i32(loc_1124_, 0) then
																											end
																										end
																										__spider_scoped_dependencies[7][1](loc_1091_, 48, bit32_or(loc_1108_ + 18, 0), 18, 0, loc_1125_)
																										loc_1125_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																										if not (rt_not_equal_i32(rt_and_i32(loc_1125_, 32), 0)) then
																											loc_1124_ = __spider_scoped_dependencies[1];
																											__spider_scoped_dependencies[1] = loc_1124_;
																											loc_1125_ = loc_1078_;
																											loc_1126_ = loc_1124_[1](loc_1126_, bit32_or(loc_1098_ - loc_1126_, 0), loc_1091_, loc_1125_)
																										end
																									else
																										loc_1117_, loc_1123_ = loc_1123_, loc_1117_;
																										loc_1121_, loc_1126_ = loc_1126_, loc_1121_;
																										if rt_greater_than_u32(loc_1118_, loc_1111_) then
																											loc_1117_ = loc_1111_;
																											loc_1121_ = loc_1118_;
																											loc_1123_ = loc_1124_;
																											loc_1124_ = __spider_scoped_dependencies[7];
																											loc_1126_ = loc_1125_;
																											loc_1125_ = loc_1122_;
																											loc_1122_ = loc_1115_;
																										else
																											loc_1117_ = loc_1111_;
																											loc_1121_ = loc_1118_;
																											loc_1123_ = loc_1124_;
																											loc_1124_ = __spider_scoped_dependencies[7];
																											loc_1126_ = loc_1125_;
																											loc_1125_ = loc_1122_;
																											loc_1122_ = loc_1115_;
																											loc_1117_ = loc_1121_;
																										end
																										loc_1121_ = loc_1117_;
																										repeat
																											rt_yield_budget = rt_yield_budget - 1
																											if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																											loc_1125_ = buffer_read_i32(loc_1081_[1], loc_1121_, 0);
																											if rt_equal_i32(loc_1125_, 0) then
																												loc_1110_ = loc_1111_;
																												loc_1118_ = 9;
																												if rt_not_equal_i32(loc_1121_, loc_1117_) then
																													loc_1115_ = 1;
																												else
																													loc_1115_ = 0;
																												end
																											else
																												loc_1110_ = loc_1111_;
																												loc_1119_ = 8;
																												repeat
																													rt_yield_budget = rt_yield_budget - 1
																													if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																													loc_1118_ = loc_1125_;
																													loc_1115_ = rt_divide_u32(loc_1118_, 10);
																													rt_store_i32_into_i8(loc_1081_, bit32_or(bit32_or(loc_1082_ + 64, 0) + loc_1119_, 0), 0, rt_or_i32(bit32_or(loc_1118_ - rt_multiply_i32(loc_1115_, 10), 0), 48))
																													loc_1125_ = loc_1115_;
																													loc_1119_ = bit32_or(loc_1119_ + -1, 0);
																												until not (rt_greater_than_u32(loc_1118_, 9))
																												loc_1118_ = bit32_or(loc_1119_ + 1, 0);
																												loc_1125_ = bit32_or(loc_1118_ + bit32_or(loc_1082_ + 64, 0), 0);
																												if rt_equal_i32(loc_1121_, loc_1117_) then
																													if rt_not_equal_i32(loc_1119_, 8) then
																														loc_1115_ = 2;
																													else
																														loc_1115_ = 0;
																													end
																												else
																													if rt_less_than_s32(bit32_or(loc_1119_ + 2, 0), 2) then
																														loc_1115_ = 2;
																													else
																														loc_1115_ = 1;
																													end
																												end
																											end
																											if (loc_1115_) >= 0 and (loc_1115_) < 2 then
																												if (loc_1115_) < 1 then
																													loc_1115_ = loc_1125_;
																													loc_1125_ = loc_1104_;
																													rt_store_i32_into_i8(loc_1081_, loc_1082_, 72, 48)
																													loc_1104_ = loc_1125_;
																												else
																													loc_1119_ = bit32_or(loc_1118_ + bit32_or(loc_1082_ + 64, 0), 0);
																													loc_1125_ = bit32_or(loc_1082_ + 64, 0);
																													loc_1115_ = bit32_or(loc_1103_ + loc_1118_, 0);
																													if not (rt_less_than_u32(bit32_or(loc_1082_ + 64, 0), loc_1115_)) then
																														loc_1125_ = loc_1115_;
																													end
																													loc_1119_ = bit32_or(loc_1119_ - loc_1125_, 0);
																													if not (rt_equal_i32(loc_1119_, 0)) then
																														rt_memory_fill(loc_1081_, loc_1125_, 48, loc_1119_)
																													end
																												end
																											else
																											end
																											loc_1115_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																											if not (rt_not_equal_i32(rt_and_i32(loc_1115_, 32), 0)) then
																												loc_1115_ = __spider_scoped_dependencies[1];
																												__spider_scoped_dependencies[1] = loc_1115_;
																												loc_1115_ = loc_1115_[1](loc_1125_, bit32_or(loc_1105_ - loc_1125_, 0), loc_1091_, loc_1126_)
																											end
																											loc_1115_ = bit32_or(loc_1121_ + 4, 0);
																											loc_1121_ = loc_1115_;
																											loc_1111_ = loc_1110_;
																										until not (rt_less_than_equal_u32(loc_1115_, loc_1110_))
																										if not (rt_equal_i32(loc_1122_, 0)) then
																											loc_1122_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																											if not (rt_not_equal_i32(rt_and_i32(loc_1122_, 32), 0)) then
																												loc_1122_ = __spider_scoped_dependencies[1];
																												__spider_scoped_dependencies[1] = loc_1122_;
																												loc_1122_ = loc_1122_[1](1106, 1, loc_1091_, loc_1126_)
																											end
																										end
																										if rt_greater_than_equal_s32(loc_1108_, 1) then
																											if rt_less_than_u32(loc_1121_, loc_1116_) then
																												repeat
																													rt_yield_budget = rt_yield_budget - 1
																													if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																													loc_1122_ = loc_1119_;
																													loc_1119_ = loc_1118_;
																													loc_1123_, loc_1125_ = loc_1125_, loc_1123_;
																													loc_1125_ = buffer_read_i32(loc_1081_[1], loc_1121_, 0);
																													if rt_not_equal_i32(loc_1125_, 0) then
																														loc_1118_ = loc_1105_;
																														loc_1123_ = loc_1121_;
																														loc_1105_ = loc_1118_;
																														loc_1119_ = loc_1118_;
																														repeat
																															rt_yield_budget = rt_yield_budget - 1
																															if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																															loc_1122_ = loc_1125_;
																															loc_1125_ = loc_1117_;
																															loc_1119_ = bit32_or(loc_1119_ + -1, 0);
																															loc_1121_ = rt_divide_u32(loc_1122_, 10);
																															rt_store_i32_into_i8(loc_1081_, loc_1119_, 0, rt_or_i32(bit32_or(loc_1122_ - rt_multiply_i32(loc_1121_, 10), 0), 48))
																															loc_1125_ = loc_1121_;
																															loc_1118_ = bit32_or(loc_1118_ + -1, 0);
																															loc_1122_ = (rt_greater_than_u32(loc_1122_, 9) and 1 or 0);
																															loc_1117_ = loc_1122_;
																														until loc_1122_ == 0
																														if rt_less_than_equal_u32(loc_1119_, bit32_or(loc_1082_ + 64, 0)) then
																															loc_1125_ = 1;
																														else
																															loc_1125_ = 0;
																														end
																													else
																														loc_1118_ = loc_1105_;
																														loc_1123_ = loc_1121_;
																														loc_1125_ = 0;
																														loc_1105_ = loc_1118_;
																														loc_1119_ = loc_1118_;
																													end
																													if not (rt_not_equal_i32(loc_1125_, 0)) then
																														loc_1125_ = bit32_or(loc_1118_ - bit32_or(loc_1082_ + 64, 0), 0);
																														loc_1119_ = bit32_or(bit32_or(loc_1119_ + bit32_or(loc_1082_ + 64, 0), 0) - loc_1118_, 0);
																														if not (rt_equal_i32(loc_1125_, 0)) then
																															rt_memory_fill(loc_1081_, loc_1119_, 48, loc_1125_)
																														end
																													end
																													loc_1125_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																													if not (rt_not_equal_i32(rt_and_i32(loc_1125_, 32), 0)) then
																														loc_1115_ = 9;
																														if rt_less_than_u32(loc_1108_, 9) then
																															loc_1121_ = __spider_scoped_dependencies[1];
																															loc_1122_ = loc_1119_;
																															loc_1125_ = loc_1108_;
																														else
																															loc_1121_ = __spider_scoped_dependencies[1];
																															loc_1122_ = loc_1119_;
																															loc_1125_ = loc_1108_;
																															loc_1125_ = loc_1115_;
																														end
																														__spider_scoped_dependencies[1] = loc_1121_;
																														loc_1125_ = loc_1121_[1](loc_1122_, loc_1125_, loc_1091_, loc_1126_)
																													end
																													loc_1125_ = bit32_or(loc_1108_ + -9, 0);
																													loc_1121_ = bit32_or(loc_1123_ + 4, 0);
																													if rt_greater_than_equal_u32(loc_1121_, loc_1116_) then
																														loc_1122_ = 0;
																														loc_1123_ = 1;
																													else
																														loc_1123_ = loc_1119_;
																														loc_1119_ = (rt_greater_than_s32(loc_1108_, 9) and 1 or 0);
																														if rt_not_equal_i32(loc_1119_, 0) then
																															loc_1108_ = loc_1125_;
																															loc_1122_ = 1;
																															loc_1123_ = 65535;
																														else
																															loc_1108_ = loc_1125_;
																															loc_1122_ = 0;
																															loc_1123_ = 0;
																														end
																													end
																												until loc_1122_ == 0
																												if rt_not_equal_i32(loc_1123_, 0) then
																												end
																											else
																												loc_1123_, loc_1125_ = loc_1125_, loc_1123_;
																												loc_1125_ = loc_1108_;
																											end
																										else
																											loc_1123_, loc_1125_ = loc_1125_, loc_1123_;
																											loc_1125_ = loc_1108_;
																										end
																										__spider_scoped_dependencies[7] = loc_1124_;
																										loc_1124_[1](loc_1091_, 48, bit32_or(loc_1125_ + 9, 0), 9, 0, loc_1126_)
																									end
																									if not (rt_not_equal_i32(loc_1120_, 8192)) then
																										if not (rt_less_than_equal_s32(loc_1114_, loc_1127_)) then
																											loc_1125_ = loc_1118_;
																											loc_1126_ = loc_1119_;
																											loc_1118_ = bit32_or(loc_1114_ - loc_1127_, 0);
																											loc_1119_ = (rt_less_than_u32(loc_1118_, 256) and 1 or 0);
																											loc_1125_ = 256;
																											if rt_not_equal_i32(loc_1119_, 0) then
																												loc_1126_ = loc_1118_;
																											else
																												loc_1124_ = loc_1118_;
																												loc_1126_ = loc_1118_;
																												loc_1118_ = loc_1125_;
																											end
																											if not (rt_equal_i32(loc_1118_, 0)) then
																												rt_memory_fill(loc_1081_, bit32_or(loc_1082_ + 608, 0), 32, loc_1118_)
																											end
																											if not (rt_not_equal_i32(loc_1119_, 0)) then
																												repeat
																													rt_yield_budget = rt_yield_budget - 1
																													if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																													loc_1125_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																													if not (rt_not_equal_i32(rt_and_i32(loc_1125_, 32), 0)) then
																														loc_1124_ = __spider_scoped_dependencies[1];
																														__spider_scoped_dependencies[1] = loc_1124_;
																														loc_1125_ = loc_1078_;
																														loc_1125_ = loc_1124_[1](bit32_or(loc_1082_ + 608, 0), 256, loc_1091_, loc_1125_)
																													end
																													loc_1125_ = bit32_or(loc_1126_ + -256, 0);
																													loc_1126_ = loc_1125_;
																												until not (rt_greater_than_u32(loc_1125_, 255))
																											end
																											loc_1125_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																											if not (rt_not_equal_i32(rt_and_i32(loc_1125_, 32), 0)) then
																												loc_1124_ = __spider_scoped_dependencies[1];
																												__spider_scoped_dependencies[1] = loc_1124_;
																												loc_1125_ = loc_1078_;
																												loc_1126_ = loc_1124_[1](bit32_or(loc_1082_ + 608, 0), loc_1126_, loc_1091_, loc_1125_)
																											end
																										end
																									end
																									if rt_greater_than_s32(loc_1114_, loc_1127_) then
																										loc_1109_ = loc_1114_;
																										loc_1110_ = loc_1127_;
																									else
																										loc_1109_ = loc_1114_;
																										loc_1110_ = loc_1127_;
																										loc_1126_ = loc_1114_;
																										loc_1114_ = loc_1127_;
																									end
																									loc_1122_ = 4;
																									loc_1115_ = 1;
																									loc_1096_ = 65535;
																								end
																							else
																								loc_1090_, loc_1127_ = loc_1127_, loc_1090_;
																								loc_1127_, loc_1126_ = loc_1126_, loc_1127_;
																								loc_1126_, loc_1125_ = loc_1125_, loc_1126_;
																								loc_1125_, loc_1124_ = loc_1124_, loc_1125_;
																								loc_1124_, loc_1123_ = loc_1123_, loc_1124_;
																								loc_1123_, loc_1122_ = loc_1122_, loc_1123_;
																								loc_1122_ = 4;
																							end
																						else
																							loc_1122_ = 4;
																						end
																					end
																				end
																			else
																				loc_1122_ = loc_1110_;
																				loc_1124_ = loc_1111_;
																				loc_1125_ = loc_1114_;
																				loc_1126_ = loc_1132_;
																				loc_1132_ = loc_1115_;
																				loc_1115_ = loc_1096_;
																				loc_1132_ = bit32_or(loc_1116_ + 3, 0);
																				if rt_not_equal_i32(rt_and_i32(loc_1120_, 8192), 0) then
																					loc_1078_ = loc_1126_;
																					loc_1082_ = loc_1123_;
																					loc_1110_ = loc_1128_;
																					loc_1111_ = loc_1127_;
																					loc_1114_ = loc_1109_;
																					loc_1128_ = loc_1117_;
																					loc_1117_ = loc_1129_;
																					loc_1129_ = loc_1116_;
																					loc_1116_ = loc_1102_;
																					loc_1102_ = loc_1119_;
																					loc_1118_, loc_1130_ = loc_1130_, loc_1118_;
																					loc_1130_, loc_1131_ = loc_1131_, loc_1130_;
																				else
																					loc_1078_ = loc_1126_;
																					loc_1082_ = loc_1123_;
																					loc_1110_ = loc_1128_;
																					loc_1111_ = loc_1127_;
																					loc_1114_ = loc_1109_;
																					loc_1128_ = loc_1117_;
																					loc_1117_ = loc_1129_;
																					loc_1129_ = loc_1116_;
																					loc_1116_ = loc_1102_;
																					loc_1102_ = loc_1119_;
																					loc_1118_, loc_1130_ = loc_1130_, loc_1118_;
																					loc_1130_, loc_1131_ = loc_1131_, loc_1130_;
																					if not (rt_less_than_equal_u32(loc_1114_, loc_1132_)) then
																						loc_1127_ = loc_1118_;
																						loc_1126_ = bit32_or(loc_1114_ - loc_1132_, 0);
																						loc_1118_ = (rt_less_than_u32(loc_1126_, 256) and 1 or 0);
																						loc_1125_ = 256;
																						if rt_not_equal_i32(loc_1118_, 0) then
																							loc_1127_ = loc_1126_;
																						else
																							loc_1127_ = loc_1126_;
																							loc_1126_ = loc_1125_;
																						end
																						if not (rt_equal_i32(loc_1126_, 0)) then
																							rt_memory_fill(loc_1081_, bit32_or(loc_1082_ + 608, 0), 32, loc_1126_)
																						end
																						if not (rt_not_equal_i32(loc_1118_, 0)) then
																							loc_1126_ = loc_1108_;
																							repeat
																								rt_yield_budget = rt_yield_budget - 1
																								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																								loc_1126_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																								if not (rt_not_equal_i32(rt_and_i32(loc_1126_, 32), 0)) then
																									loc_1125_ = __spider_scoped_dependencies[1];
																									__spider_scoped_dependencies[1] = loc_1125_;
																									loc_1126_ = loc_1078_;
																									loc_1126_ = loc_1125_[1](bit32_or(loc_1082_ + 608, 0), 256, loc_1091_, loc_1126_)
																								end
																								loc_1126_ = bit32_or(loc_1127_ + -256, 0);
																								loc_1127_ = loc_1126_;
																							until not (rt_greater_than_u32(loc_1126_, 255))
																							loc_1108_ = buffer_read_i32(loc_1081_[1], loc_1091_, 0);
																						end
																						if not (rt_not_equal_i32(rt_and_i32(loc_1108_, 32), 0)) then
																							loc_1125_ = __spider_scoped_dependencies[1];
																							loc_1126_ = loc_1108_;
																							__spider_scoped_dependencies[1] = loc_1125_;
																							loc_1126_ = loc_1078_;
																							loc_1127_ = loc_1125_[1](bit32_or(loc_1082_ + 608, 0), loc_1127_, loc_1091_, loc_1126_)
																							loc_1108_ = buffer_read_i32(loc_1081_[1], loc_1091_, 0);
																						end
																					end
																				end
																				if not (rt_not_equal_i32(rt_and_i32(loc_1108_, 32), 0)) then
																					loc_1126_ = __spider_scoped_dependencies[1];
																					loc_1127_ = loc_1108_;
																					__spider_scoped_dependencies[1] = loc_1126_;
																					loc_1127_ = loc_1078_;
																					loc_1129_ = loc_1126_[1](loc_1128_, loc_1129_, loc_1091_, loc_1127_)
																					loc_1108_ = buffer_read_i32(loc_1081_[1], loc_1091_, 0);
																				end
																				if not (rt_not_equal_i32(rt_and_i32(loc_1108_, 32), 0)) then
																					loc_1125_ = rt_and_i32(loc_1131_, 32);
																					loc_1131_ = 1070;
																					loc_1128_ = 1098;
																					if rt_not_equal_i32(loc_1125_, 0) then
																						loc_1127_ = loc_1130_;
																						loc_1129_ = __spider_scoped_dependencies[1];
																						loc_1130_ = loc_1131_;
																						loc_1131_ = loc_1078_;
																					else
																						loc_1127_ = loc_1130_;
																						loc_1129_ = __spider_scoped_dependencies[1];
																						loc_1130_ = loc_1131_;
																						loc_1131_ = loc_1078_;
																						loc_1130_ = loc_1128_;
																					end
																					loc_1128_ = 1074;
																					loc_1126_ = 1102;
																					if not (rt_not_equal_i32(loc_1125_, 0)) then
																						loc_1128_ = loc_1126_;
																					end
																					if not (rt_not_equal_f64(loc_1127_, loc_1127_)) then
																						loc_1130_ = loc_1128_;
																					end
																					__spider_scoped_dependencies[1] = loc_1129_;
																					loc_1131_ = loc_1129_[1](loc_1130_, 3, loc_1091_, loc_1131_)
																				end
																				if not (rt_not_equal_i32(rt_and_i32(loc_1120_, 73728), 8192)) then
																					if not (rt_less_than_equal_u32(loc_1114_, loc_1132_)) then
																						loc_1131_ = loc_1118_;
																						loc_1130_ = bit32_or(loc_1114_ - loc_1132_, 0);
																						loc_1118_ = (rt_less_than_u32(loc_1130_, 256) and 1 or 0);
																						loc_1129_ = 256;
																						if rt_not_equal_i32(loc_1118_, 0) then
																							loc_1131_ = loc_1130_;
																						else
																							loc_1131_ = loc_1130_;
																							loc_1130_ = loc_1129_;
																						end
																						if not (rt_equal_i32(loc_1130_, 0)) then
																							rt_memory_fill(loc_1081_, bit32_or(loc_1082_ + 608, 0), 32, loc_1130_)
																						end
																						if not (rt_not_equal_i32(loc_1118_, 0)) then
																							repeat
																								rt_yield_budget = rt_yield_budget - 1
																								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																								loc_1130_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																								if not (rt_not_equal_i32(rt_and_i32(loc_1130_, 32), 0)) then
																									loc_1129_ = __spider_scoped_dependencies[1];
																									__spider_scoped_dependencies[1] = loc_1129_;
																									loc_1130_ = loc_1078_;
																									loc_1130_ = loc_1129_[1](bit32_or(loc_1082_ + 608, 0), 256, loc_1091_, loc_1130_)
																								end
																								loc_1130_ = bit32_or(loc_1131_ + -256, 0);
																								loc_1131_ = loc_1130_;
																							until not (rt_greater_than_u32(loc_1130_, 255))
																						end
																						loc_1130_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																						if not (rt_not_equal_i32(rt_and_i32(loc_1130_, 32), 0)) then
																							loc_1129_ = __spider_scoped_dependencies[1];
																							__spider_scoped_dependencies[1] = loc_1129_;
																							loc_1130_ = loc_1078_;
																							loc_1131_ = loc_1129_[1](bit32_or(loc_1082_ + 608, 0), loc_1131_, loc_1091_, loc_1130_)
																						end
																					end
																				end
																				if rt_greater_than_u32(loc_1114_, loc_1132_) then
																					loc_1109_ = loc_1114_;
																					loc_1119_ = loc_1132_;
																				else
																					loc_1109_ = loc_1114_;
																					loc_1119_ = loc_1132_;
																					loc_1131_ = loc_1114_;
																					loc_1114_ = loc_1132_;
																				end
																				loc_1122_ = 4;
																				loc_1115_ = 1;
																				loc_1096_ = 65535;
																			end
																		end
																	else
																		loc_1123_ = loc_1122_;
																		loc_1122_ = loc_1108_;
																		loc_1108_ = loc_1112_;
																		loc_1112_ = loc_1090_;
																		loc_1112_ = rt_load_i64(loc_1081_, loc_1082_, 40);
																		if rt_greater_than_s64(loc_1112_, into_bits_i64(4294967295, 4294967295)) then
																			if rt_equal_i32(rt_and_i32(loc_1120_, 2048), 0) then
																				loc_1108_ = rt_and_i32(loc_1120_, 1);
																				loc_1111_ = 1026;
																				loc_1123_ = 1024;
																				if not (rt_not_equal_i32(loc_1108_, 0)) then
																					loc_1122_ = loc_1111_;
																					loc_1111_ = loc_1123_;
																				end
																				loc_1122_ = 1;
																			else
																				loc_1122_ = 1;
																				loc_1108_ = 1;
																				loc_1111_ = 1025;
																			end
																		else
																			loc_1112_ = rt_subtract_i64(into_bits_i64(0, 0), loc_1112_);
																			rt_store_i64(loc_1081_, loc_1082_, 40, loc_1112_)
																			loc_1122_ = 1;
																			loc_1108_ = 1;
																			loc_1111_ = 1024;
																		end
																	end
																else
																	loc_1125_ = loc_1111_;
																	loc_1126_ = loc_1090_;
																	loc_1127_ = loc_1117_;
																	loc_1128_ = loc_1108_;
																	loc_1129_ = loc_1122_;
																	loc_1130_ = loc_1119_;
																	loc_1131_ = loc_1107_;
																	loc_1132_ = loc_1101_;
																	rt_store_i32_into_i8(loc_1081_, loc_1082_, 39, loc_1114_)
																	loc_1122_ = 3;
																	loc_1101_ = loc_1132_;
																	loc_1107_ = loc_1131_;
																	loc_1114_ = loc_1131_;
																	loc_1119_ = loc_1132_;
																	loc_1108_ = 0;
																	loc_1117_ = 1;
																	loc_1111_ = 1024;
																end
															elseif (loc_1132_) > 5 then
																if (loc_1132_) < 8 then
																	if (loc_1132_) < 7 then
																		loc_1123_ = loc_1122_;
																		loc_1122_ = loc_1090_;
																		loc_1122_ = 1;
																	else
																		loc_1123_ = loc_1119_;
																		loc_1119_ = loc_1108_;
																		loc_1111_, loc_1112_ = loc_1112_, loc_1111_;
																		loc_1112_ = rt_load_i64(loc_1081_, loc_1082_, 40);
																		loc_1108_ = 0;
																		loc_1111_ = 1024;
																		if rt_equal_i32((rt_equal_i64(loc_1112_, into_bits_i64(0, 0)) and 1 or 0), 0) then
																			loc_1119_ = loc_1107_;
																			loc_1122_ = loc_1090_;
																			loc_1107_ = loc_1119_;
																			loc_1090_ = rt_and_i32(loc_1122_, 32);
																			repeat
																				rt_yield_budget = rt_yield_budget - 1
																				if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																				loc_1123_ = loc_1114_;
																				loc_1123_ = rt_load_i32_from_u8(loc_1081_, rt_and_i32(rt_narrow_i64(loc_1112_), 15), 6448);
																				loc_1119_ = bit32_or(loc_1119_ + -1, 0);
																				rt_store_i32_into_i8(loc_1081_, loc_1119_, 0, rt_or_i32(loc_1123_, loc_1090_))
																				loc_1123_ = (rt_greater_than_u64(loc_1112_, into_bits_i64(15, 0)) and 1 or 0);
																				loc_1114_ = loc_1123_;
																				loc_1112_ = rt_shift_right_u64(loc_1112_, into_bits_i64(4, 0));
																			until loc_1123_ == 0
																			if rt_equal_i32(rt_and_i32(loc_1120_, 8), 0) then
																				loc_1122_ = 2;
																			else
																				loc_1108_, loc_1111_ = loc_1111_, loc_1108_;
																				loc_1111_, loc_1122_ = loc_1122_, loc_1111_;
																				loc_1122_ = 2;
																				loc_1108_ = 2;
																				loc_1111_ = bit32_or(rt_shift_right_u32(loc_1111_, 4) + 1024, 0);
																			end
																		else
																			loc_1119_ = loc_1107_;
																			loc_1123_ = loc_1090_;
																			loc_1122_ = 2;
																			loc_1107_ = loc_1119_;
																		end
																	end
																elseif (loc_1132_) > 8 then
																	loc_1090_, loc_1111_ = loc_1111_, loc_1090_;
																	loc_1111_, loc_1117_ = loc_1117_, loc_1111_;
																	loc_1117_, loc_1121_ = loc_1121_, loc_1117_;
																	loc_1121_, loc_1107_ = loc_1107_, loc_1121_;
																	loc_1108_, loc_1116_ = loc_1116_, loc_1108_;
																	loc_1116_, loc_1122_ = loc_1122_, loc_1116_;
																	loc_1122_, loc_1114_ = loc_1114_, loc_1122_;
																	loc_1122_ = 3;
																	loc_1107_ = loc_1121_;
																	loc_1114_ = loc_1121_;
																	loc_1108_ = 0;
																	loc_1121_ = loc_1117_;
																	loc_1116_ = loc_1120_;
																	loc_1111_ = 1024;
																else
																	loc_1122_ = 2;
																end
															else
																loc_1123_ = loc_1114_;
																loc_1114_ = loc_1117_;
																loc_1117_ = loc_1108_;
																loc_1108_ = loc_1111_;
																loc_1111_ = loc_1090_;
																loc_1111_ = 2147483647;
																if rt_less_than_u32(loc_1121_, 2147483647) then
																	loc_1114_ = loc_1119_;
																	loc_1117_ = loc_1121_;
																	loc_1122_ = loc_1078_;
																	loc_1123_ = loc_1119_;
																else
																	loc_1114_ = loc_1119_;
																	loc_1117_ = loc_1121_;
																	loc_1122_ = loc_1078_;
																	loc_1123_ = loc_1119_;
																	loc_1117_ = loc_1111_;
																end
																loc_1117_ = __spider_scoped_dependencies[3][1](loc_1114_, loc_1117_, loc_1122_)
																loc_1114_ = bit32_or(loc_1123_ + loc_1117_, 0);
																loc_1108_ = 0;
																loc_1111_ = 1024;
																if rt_greater_than_s32(loc_1121_, -1) then
																	loc_1122_ = 3;
																else
																	loc_1123_ = rt_load_i32_from_u8(loc_1081_, loc_1114_, 0);
																	if rt_equal_i32(loc_1123_, 0) then
																		loc_1122_ = 3;
																	else
																		loc_1122_ = loc_1096_;
																		loc_1123_ = loc_1115_;
																		loc_1122_ = 4;
																		loc_1115_ = 0;
																		loc_1096_ = 3;
																	end
																end
															end
														else
															loc_1122_ = 4;
														end
														if (loc_1122_) >= 0 and (loc_1122_) < 4 then
															if (loc_1122_) < 2 then
																if (loc_1122_) < 1 then
																	loc_1122_ = loc_1115_;
																	loc_1115_ = loc_1096_;
																	loc_1122_ = loc_1078_;
																	__spider_scoped_dependencies[7][1](loc_1091_, 32, loc_1109_, loc_1114_, rt_exclusive_or_i32(loc_1120_, 8192), loc_1122_)
																	if rt_greater_than_s32(loc_1109_, loc_1114_) then
																		loc_1122_ = loc_1114_;
																		loc_1114_ = loc_1109_;
																	else
																		loc_1115_ = loc_1109_;
																		loc_1122_ = loc_1114_;
																		loc_1114_ = loc_1122_;
																	end
																	loc_1090_ = 2;
																	loc_1115_ = 1;
																	loc_1096_ = 65535;
																else
																	loc_1122_ = loc_1119_;
																	if rt_greater_than_equal_u64(loc_1112_, into_bits_i64(0, 1)) then
																		loc_1119_ = loc_1107_;
																		loc_1107_ = loc_1119_;
																		repeat
																			rt_yield_budget = rt_yield_budget - 1
																			if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																			loc_1122_ = loc_1114_;
																			loc_1114_ = loc_1113_;
																			loc_1119_ = bit32_or(loc_1119_ + -1, 0);
																			loc_1090_ = rt_divide_u64(loc_1112_, into_bits_i64(10, 0));
																			rt_store_i32_into_i8(loc_1081_, loc_1119_, 0, rt_or_i32(rt_narrow_i64(rt_subtract_i64(loc_1112_, rt_multiply_i64(loc_1090_, into_bits_i64(10, 0)))), 48))
																			loc_1122_ = (rt_greater_than_u64(loc_1112_, into_bits_i64(4294967295, 9)) and 1 or 0);
																			loc_1114_ = loc_1122_;
																			loc_1112_ = loc_1090_;
																			loc_1113_ = loc_1090_;
																		until loc_1122_ == 0
																	else
																		loc_1119_ = loc_1107_;
																		loc_1122_ = loc_1112_;
																		loc_1107_ = loc_1119_;
																		loc_1112_ = loc_1122_;
																		loc_1113_ = loc_1122_;
																	end
																	if rt_equal_i64(loc_1113_, into_bits_i64(0, 0)) then
																		loc_1090_ = 0;
																	else
																		loc_1122_ = loc_1114_;
																		loc_1114_ = rt_narrow_i64(loc_1113_);
																		repeat
																			rt_yield_budget = rt_yield_budget - 1
																			if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																			loc_1122_ = loc_1117_;
																			loc_1117_ = loc_1114_;
																			loc_1119_ = bit32_or(loc_1119_ + -1, 0);
																			loc_1122_ = rt_divide_u32(loc_1117_, 10);
																			rt_store_i32_into_i8(loc_1081_, loc_1119_, 0, rt_or_i32(bit32_or(loc_1117_ - rt_multiply_i32(loc_1122_, 10), 0), 48))
																			loc_1114_ = loc_1122_;
																			loc_1090_ = (rt_greater_than_u32(loc_1117_, 9) and 1 or 0);
																			loc_1117_ = loc_1090_;
																		until loc_1090_ == 0
																		loc_1090_ = 0;
																	end
																end
															elseif (loc_1122_) > 2 then
																loc_1090_ = 1;
															else
																loc_1090_ = 0;
															end
														else
															loc_1090_ = 2;
														end
														if (loc_1090_) >= 0 and (loc_1090_) < 2 then
															if (loc_1090_) < 1 then
																if rt_not_equal_i32(rt_and_i32(loc_1110_, (rt_less_than_s32(loc_1121_, 0) and 1 or 0)), 0) then
																	loc_1096_, loc_1120_ = loc_1120_, loc_1096_;
																	loc_1115_, loc_1121_ = loc_1121_, loc_1115_;
																	loc_1121_ = 1;
																	loc_1115_ = 0;
																	loc_1096_ = 13;
																else
																	loc_1096_, loc_1120_ = loc_1120_, loc_1096_;
																	loc_1115_, loc_1121_ = loc_1121_, loc_1115_;
																	loc_1116_ = rt_and_i32(loc_1096_, -65537);
																	if rt_not_equal_i32(loc_1110_, 0) then
																		loc_1096_, loc_1120_ = loc_1120_, loc_1096_;
																		loc_1115_, loc_1121_ = loc_1121_, loc_1115_;
																	else
																		loc_1096_, loc_1120_ = loc_1120_, loc_1096_;
																		loc_1115_, loc_1121_ = loc_1121_, loc_1115_;
																		loc_1116_ = loc_1120_;
																	end
																	loc_1112_ = rt_load_i64(loc_1081_, loc_1082_, 40);
																	if rt_not_equal_i64(loc_1112_, into_bits_i64(0, 0)) then
																		loc_1120_ = 0;
																	else
																		loc_1120_ = loc_1117_;
																		loc_1117_ = 0;
																		if rt_not_equal_i32(loc_1121_, 0) then
																			loc_1120_ = 0;
																		else
																			loc_1120_ = loc_1114_;
																			loc_1114_ = loc_1119_;
																			loc_1119_ = loc_1107_;
																			loc_1120_ = 1;
																			loc_1107_ = loc_1119_;
																			loc_1114_ = loc_1119_;
																		end
																	end
																	if rt_not_equal_i32(loc_1120_, 0) then
																		loc_1121_ = 0;
																	else
																		loc_1120_ = loc_1114_;
																		loc_1120_ = bit32_or(bit32_or(loc_1107_ - loc_1119_, 0) + (rt_equal_i64(loc_1112_, into_bits_i64(0, 0)) and 1 or 0), 0);
																		if rt_greater_than_s32(loc_1121_, loc_1120_) then
																			loc_1114_ = loc_1107_;
																			loc_1117_ = loc_1121_;
																			loc_1121_ = loc_1120_;
																		else
																			loc_1114_ = loc_1107_;
																			loc_1120_, loc_1121_ = loc_1121_, loc_1120_;
																			loc_1117_ = loc_1121_;
																		end
																		loc_1121_ = 0;
																		loc_1107_ = loc_1114_;
																	end
																end
															else
																loc_1121_ = 0;
															end
														else
															loc_1121_ = 1;
														end
														if not (rt_not_equal_i32(loc_1121_, 0)) then
															loc_1120_ = loc_1096_;
															loc_1121_ = loc_1115_;
															loc_1115_ = loc_1110_;
															loc_1121_ = bit32_or(loc_1114_ - loc_1119_, 0);
															if rt_greater_than_s32(loc_1117_, loc_1121_) then
																loc_1110_ = loc_1117_;
																loc_1115_ = loc_1116_;
																loc_1116_ = loc_1117_;
																loc_1117_ = loc_1121_;
															else
																loc_1115_ = loc_1116_;
																loc_1116_ = loc_1117_;
																loc_1120_ = loc_1117_;
																loc_1117_ = loc_1121_;
																loc_1110_ = loc_1121_;
															end
															if rt_greater_than_s32(loc_1110_, rt_exclusive_or_i32(loc_1108_, 2147483647)) then
																loc_1115_ = 0;
																loc_1096_ = 21;
															else
																loc_1121_ = loc_1114_;
																loc_1120_ = bit32_or(loc_1108_ + loc_1110_, 0);
																if rt_greater_than_s32(loc_1109_, loc_1120_) then
																	loc_1114_ = loc_1109_;
																	loc_1121_ = loc_1118_;
																	loc_1118_ = loc_1120_;
																else
																	loc_1114_ = loc_1109_;
																	loc_1121_ = loc_1118_;
																	loc_1118_ = loc_1120_;
																	loc_1114_ = loc_1120_;
																end
																if rt_greater_than_u32(loc_1114_, loc_1121_) then
																	loc_1115_ = 0;
																	loc_1096_ = 22;
																else
																	loc_1121_ = rt_and_i32(loc_1115_, 73728);
																	if rt_not_equal_i32(loc_1121_, 0) then
																		loc_1115_ = loc_1116_;
																		loc_1116_ = loc_1117_;
																		loc_1117_ = loc_1119_;
																		loc_1119_ = loc_1118_;
																		loc_1118_ = loc_1121_;
																	else
																		loc_1115_ = loc_1116_;
																		loc_1116_ = loc_1117_;
																		loc_1117_ = loc_1119_;
																		loc_1119_ = loc_1118_;
																		loc_1118_ = loc_1121_;
																		if not (rt_less_than_equal_s32(loc_1109_, loc_1119_)) then
																			loc_1120_ = bit32_or(loc_1114_ - loc_1119_, 0);
																			loc_1090_ = (rt_less_than_u32(loc_1120_, 256) and 1 or 0);
																			loc_1121_ = 256;
																			if rt_not_equal_i32(loc_1090_, 0) then
																				loc_1096_ = loc_1120_;
																			else
																				loc_1096_ = loc_1120_;
																				loc_1120_ = loc_1121_;
																			end
																			if not (rt_equal_i32(loc_1120_, 0)) then
																				rt_memory_fill(loc_1081_, bit32_or(loc_1082_ + 96, 0), 32, loc_1120_)
																			end
																			if not (rt_not_equal_i32(loc_1090_, 0)) then
																				repeat
																					rt_yield_budget = rt_yield_budget - 1
																					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																					loc_1090_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																					if not (rt_not_equal_i32(rt_and_i32(loc_1090_, 32), 0)) then
																						loc_1090_ = loc_1078_;
																						loc_1078_ = __spider_scoped_dependencies[1];
																						__spider_scoped_dependencies[1] = loc_1078_;
																						loc_1090_ = loc_1078_[1](bit32_or(loc_1082_ + 96, 0), 256, loc_1091_, loc_1090_)
																					end
																					loc_1090_ = bit32_or(loc_1096_ + -256, 0);
																					loc_1096_ = loc_1090_;
																				until not (rt_greater_than_u32(loc_1090_, 255))
																			end
																			loc_1090_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																			if not (rt_not_equal_i32(rt_and_i32(loc_1090_, 32), 0)) then
																				loc_1090_ = loc_1078_;
																				loc_1078_ = __spider_scoped_dependencies[1];
																				__spider_scoped_dependencies[1] = loc_1078_;
																				loc_1096_ = loc_1078_[1](bit32_or(loc_1082_ + 96, 0), loc_1096_, loc_1091_, loc_1090_)
																			end
																		end
																	end
																	loc_1096_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																	if not (rt_not_equal_i32(rt_and_i32(loc_1096_, 32), 0)) then
																		loc_1090_ = __spider_scoped_dependencies[1];
																		__spider_scoped_dependencies[1] = loc_1090_;
																		loc_1096_ = loc_1078_;
																		loc_1096_ = loc_1090_[1](loc_1111_, loc_1108_, loc_1091_, loc_1096_)
																	end
																	if not (rt_not_equal_i32(loc_1118_, 65536)) then
																		if not (rt_less_than_equal_s32(loc_1109_, loc_1119_)) then
																			loc_1108_, loc_1111_ = loc_1111_, loc_1108_;
																			loc_1111_ = bit32_or(loc_1114_ - loc_1119_, 0);
																			loc_1108_ = (rt_less_than_u32(loc_1111_, 256) and 1 or 0);
																			loc_1090_ = 256;
																			if rt_not_equal_i32(loc_1108_, 0) then
																				loc_1096_ = loc_1111_;
																			else
																				loc_1096_ = loc_1111_;
																				loc_1111_ = loc_1090_;
																			end
																			if not (rt_equal_i32(loc_1111_, 0)) then
																				rt_memory_fill(loc_1081_, bit32_or(loc_1082_ + 96, 0), 48, loc_1111_)
																			end
																			if not (rt_not_equal_i32(loc_1108_, 0)) then
																				repeat
																					rt_yield_budget = rt_yield_budget - 1
																					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																					loc_1090_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																					if not (rt_not_equal_i32(rt_and_i32(loc_1090_, 32), 0)) then
																						loc_1090_ = loc_1078_;
																						loc_1078_ = __spider_scoped_dependencies[1];
																						__spider_scoped_dependencies[1] = loc_1078_;
																						loc_1090_ = loc_1078_[1](bit32_or(loc_1082_ + 96, 0), 256, loc_1091_, loc_1090_)
																					end
																					loc_1090_ = bit32_or(loc_1096_ + -256, 0);
																					loc_1096_ = loc_1090_;
																				until not (rt_greater_than_u32(loc_1090_, 255))
																			end
																			loc_1090_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																			if not (rt_not_equal_i32(rt_and_i32(loc_1090_, 32), 0)) then
																				loc_1090_ = loc_1078_;
																				loc_1078_ = __spider_scoped_dependencies[1];
																				__spider_scoped_dependencies[1] = loc_1078_;
																				loc_1096_ = loc_1078_[1](bit32_or(loc_1082_ + 96, 0), loc_1096_, loc_1091_, loc_1090_)
																			end
																		end
																	end
																	if not (rt_less_than_equal_s32(loc_1115_, loc_1116_)) then
																		loc_1110_ = bit32_or(loc_1110_ - loc_1116_, 0);
																		loc_1096_ = (rt_less_than_u32(loc_1110_, 256) and 1 or 0);
																		loc_1090_ = 256;
																		if rt_not_equal_i32(loc_1096_, 0) then
																			loc_1115_ = loc_1110_;
																		else
																			loc_1115_ = loc_1110_;
																			loc_1110_ = loc_1090_;
																		end
																		if not (rt_equal_i32(loc_1110_, 0)) then
																			rt_memory_fill(loc_1081_, bit32_or(loc_1082_ + 96, 0), 48, loc_1110_)
																		end
																		if not (rt_not_equal_i32(loc_1096_, 0)) then
																			repeat
																				rt_yield_budget = rt_yield_budget - 1
																				if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																				loc_1096_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																				if not (rt_not_equal_i32(rt_and_i32(loc_1096_, 32), 0)) then
																					loc_1090_ = __spider_scoped_dependencies[1];
																					__spider_scoped_dependencies[1] = loc_1090_;
																					loc_1096_ = loc_1078_;
																					loc_1096_ = loc_1090_[1](bit32_or(loc_1082_ + 96, 0), 256, loc_1091_, loc_1096_)
																				end
																				loc_1096_ = bit32_or(loc_1115_ + -256, 0);
																				loc_1115_ = loc_1096_;
																			until not (rt_greater_than_u32(loc_1096_, 255))
																		end
																		loc_1096_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																		if not (rt_not_equal_i32(rt_and_i32(loc_1096_, 32), 0)) then
																			loc_1090_ = __spider_scoped_dependencies[1];
																			__spider_scoped_dependencies[1] = loc_1090_;
																			loc_1096_ = loc_1078_;
																			loc_1115_ = loc_1090_[1](bit32_or(loc_1082_ + 96, 0), loc_1115_, loc_1091_, loc_1096_)
																		end
																	end
																	loc_1115_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																	if not (rt_not_equal_i32(rt_and_i32(loc_1115_, 32), 0)) then
																		loc_1096_ = __spider_scoped_dependencies[1];
																		__spider_scoped_dependencies[1] = loc_1096_;
																		loc_1115_ = loc_1078_;
																		loc_1117_ = loc_1096_[1](loc_1117_, loc_1116_, loc_1091_, loc_1115_)
																	end
																	if rt_not_equal_i32(loc_1118_, 8192) then
																		loc_1115_ = 1;
																		loc_1096_ = 65535;
																	else
																		if rt_less_than_equal_s32(loc_1109_, loc_1119_) then
																			loc_1115_ = 1;
																			loc_1096_ = 65535;
																		else
																			loc_1117_ = bit32_or(loc_1114_ - loc_1119_, 0);
																			loc_1118_ = (rt_less_than_u32(loc_1117_, 256) and 1 or 0);
																			loc_1116_ = 256;
																			if rt_not_equal_i32(loc_1118_, 0) then
																				loc_1119_ = loc_1117_;
																			else
																				loc_1119_ = loc_1117_;
																				loc_1117_ = loc_1116_;
																			end
																			if not (rt_equal_i32(loc_1117_, 0)) then
																				rt_memory_fill(loc_1081_, bit32_or(loc_1082_ + 96, 0), 32, loc_1117_)
																			end
																			if not (rt_not_equal_i32(loc_1118_, 0)) then
																				repeat
																					rt_yield_budget = rt_yield_budget - 1
																					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																					loc_1118_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																					if not (rt_not_equal_i32(rt_and_i32(loc_1118_, 32), 0)) then
																						loc_1117_ = __spider_scoped_dependencies[1];
																						__spider_scoped_dependencies[1] = loc_1117_;
																						loc_1118_ = loc_1078_;
																						loc_1118_ = loc_1117_[1](bit32_or(loc_1082_ + 96, 0), 256, loc_1091_, loc_1118_)
																					end
																					loc_1118_ = bit32_or(loc_1119_ + -256, 0);
																					loc_1119_ = loc_1118_;
																				until not (rt_greater_than_u32(loc_1118_, 255))
																			end
																			loc_1118_ = rt_load_i32_from_u8(loc_1081_, loc_1091_, 0);
																			if rt_not_equal_i32(rt_and_i32(loc_1118_, 32), 0) then
																				loc_1115_ = 1;
																				loc_1096_ = 65535;
																			else
																				loc_1117_ = __spider_scoped_dependencies[1];
																				__spider_scoped_dependencies[1] = loc_1117_;
																				loc_1118_ = loc_1078_;
																				loc_1119_ = loc_1117_[1](bit32_or(loc_1082_ + 96, 0), loc_1119_, loc_1091_, loc_1118_)
																				loc_1115_ = 1;
																				loc_1096_ = 65535;
																			end
																		end
																	end
																end
															end
														end
													end
												end
											end
										end
									end
								end
							end
						end
					end
					loc_1090_ = loc_1115_;
				until loc_1115_ == 0
				if (loc_1096_) >= 0 and (loc_1096_) < 24 then
					if (loc_1096_) < 12 then
						if (loc_1096_) < 6 then
							if (loc_1096_) < 3 then
								if (loc_1096_) < 1 then
									rt_store_i32(loc_1081_, bit32_or(loc_1094_ + rt_shift_left_i32(loc_1108_, 2), 0), 0, loc_1114_)
									loc_1114_ = 1;
									loc_1090_ = 65535;
								elseif (loc_1096_) > 1 then
									loc_1114_ = 0;
									loc_1090_ = 1;
								else
									loc_1114_ = 0;
									loc_1090_ = 0;
								end
							elseif (loc_1096_) > 3 then
								if (loc_1096_) < 5 then
									loc_1114_ = 0;
									loc_1090_ = 3;
								else
									loc_1114_ = 0;
									loc_1090_ = 4;
								end
							else
								loc_1114_ = 0;
								loc_1090_ = 2;
							end
						elseif (loc_1096_) > 6 then
							if (loc_1096_) < 9 then
								if (loc_1096_) < 8 then
									loc_1114_ = 0;
									loc_1090_ = 4;
								else
									loc_1114_ = 0;
									loc_1090_ = 4;
								end
							elseif (loc_1096_) > 9 then
								if (loc_1096_) < 11 then
									loc_1114_ = 0;
									loc_1090_ = 5;
								else
									loc_1114_ = 0;
									loc_1090_ = 5;
								end
							else
								loc_1114_ = 0;
								loc_1090_ = 4;
							end
						else
							loc_1114_ = 0;
							loc_1090_ = 4;
						end
					elseif (loc_1096_) > 12 then
						if (loc_1096_) < 18 then
							if (loc_1096_) < 15 then
								if (loc_1096_) < 14 then
									loc_1114_ = 0;
									loc_1090_ = 5;
								else
									loc_1114_ = 0;
									loc_1090_ = 5;
								end
							elseif (loc_1096_) > 15 then
								if (loc_1096_) < 17 then
									loc_1114_ = 0;
									loc_1090_ = 5;
								else
									loc_1114_ = 0;
									loc_1090_ = 5;
								end
							else
								loc_1114_ = 0;
								loc_1090_ = 5;
							end
						elseif (loc_1096_) > 18 then
							if (loc_1096_) < 21 then
								if (loc_1096_) < 20 then
									loc_1114_ = 0;
									loc_1090_ = 5;
								else
									loc_1114_ = 0;
									loc_1090_ = 5;
								end
							elseif (loc_1096_) > 21 then
								if (loc_1096_) < 23 then
									loc_1114_ = 0;
									loc_1090_ = 5;
								else
									loc_1114_ = 0;
									loc_1090_ = 6;
								end
							else
								loc_1114_ = 0;
								loc_1090_ = 5;
							end
						else
							loc_1114_ = 0;
							loc_1090_ = 5;
						end
					else
						loc_1114_ = 0;
						loc_1090_ = 5;
					end
				else
					loc_1114_ = 0;
					loc_1090_ = 6;
				end
				loc_1096_ = loc_1114_;
			until loc_1114_ == 0
			if (loc_1090_) >= 0 and (loc_1090_) < 6 then
				if (loc_1090_) < 3 then
					if (loc_1090_) < 1 then
						loc_1090_, loc_1095_ = loc_1095_, loc_1090_;
						loc_1091_, loc_1094_ = loc_1094_, loc_1091_;
						loc_1092_, loc_1093_ = loc_1093_, loc_1092_;
						loc_1090_ = 1;
					elseif (loc_1090_) > 1 then
						loc_1090_, loc_1095_ = loc_1095_, loc_1090_;
						loc_1091_, loc_1094_ = loc_1094_, loc_1091_;
						loc_1092_, loc_1093_ = loc_1093_, loc_1092_;
						loc_1090_ = 1;
					else
						loc_1090_, loc_1095_ = loc_1095_, loc_1090_;
						loc_1091_, loc_1094_ = loc_1094_, loc_1091_;
						loc_1092_, loc_1093_ = loc_1093_, loc_1092_;
						loc_1090_ = 3;
						loc_1079_ = 0;
					end
				elseif (loc_1090_) > 3 then
					if (loc_1090_) < 5 then
						loc_1090_, loc_1095_ = loc_1095_, loc_1090_;
						loc_1091_, loc_1094_ = loc_1094_, loc_1091_;
						loc_1092_, loc_1093_ = loc_1093_, loc_1092_;
						loc_1090_ = 0;
					else
						loc_1090_, loc_1095_ = loc_1095_, loc_1090_;
						loc_1091_, loc_1094_ = loc_1094_, loc_1091_;
						loc_1092_, loc_1093_ = loc_1093_, loc_1092_;
						loc_1090_ = 1;
					end
				else
					if rt_not_equal_i32(loc_1091_, 0) then
						loc_1091_ = loc_1095_;
						loc_1095_ = loc_1090_;
						loc_1092_, loc_1094_ = loc_1094_, loc_1092_;
						loc_1090_ = 3;
					else
						loc_1091_ = loc_1095_;
						loc_1095_ = loc_1090_;
						loc_1092_, loc_1094_ = loc_1094_, loc_1092_;
						if rt_not_equal_i32(loc_1091_, 0) then
							loc_1090_ = loc_1094_;
							loc_1091_ = loc_1093_;
							loc_1093_ = loc_1092_;
							loc_1094_ = loc_1078_;
							loc_1079_, __spider_scoped_dependencies[6] = __spider_scoped_dependencies[6], loc_1079_;
							loc_1092_ = buffer_read_i32(loc_1081_[1], loc_1093_, 4);
							if rt_not_equal_i32(loc_1092_, 0) then
								loc_1079_[1](bit32_or(loc_1091_ + 8, 0), loc_1092_, loc_1090_, loc_1094_)
								loc_1092_ = buffer_read_i32(loc_1081_[1], loc_1093_, 8);
								if rt_not_equal_i32(loc_1092_, 0) then
									loc_1079_[1](bit32_or(loc_1091_ + 16, 0), loc_1092_, loc_1090_, loc_1094_)
									loc_1092_ = buffer_read_i32(loc_1081_[1], loc_1093_, 12);
									if rt_not_equal_i32(loc_1092_, 0) then
										loc_1079_[1](bit32_or(loc_1091_ + 24, 0), loc_1092_, loc_1090_, loc_1094_)
										loc_1092_ = buffer_read_i32(loc_1081_[1], loc_1093_, 16);
										if rt_not_equal_i32(loc_1092_, 0) then
											loc_1079_[1](bit32_or(loc_1091_ + 32, 0), loc_1092_, loc_1090_, loc_1094_)
											loc_1092_ = buffer_read_i32(loc_1081_[1], loc_1093_, 20);
											if rt_not_equal_i32(loc_1092_, 0) then
												loc_1079_[1](bit32_or(loc_1091_ + 40, 0), loc_1092_, loc_1090_, loc_1094_)
												loc_1092_ = buffer_read_i32(loc_1081_[1], loc_1093_, 24);
												if rt_not_equal_i32(loc_1092_, 0) then
													loc_1079_[1](bit32_or(loc_1091_ + 48, 0), loc_1092_, loc_1090_, loc_1094_)
													loc_1092_ = buffer_read_i32(loc_1081_[1], loc_1093_, 28);
													if rt_not_equal_i32(loc_1092_, 0) then
														loc_1079_[1](bit32_or(loc_1091_ + 56, 0), loc_1092_, loc_1090_, loc_1094_)
														loc_1092_ = buffer_read_i32(loc_1081_[1], loc_1093_, 32);
														if rt_not_equal_i32(loc_1092_, 0) then
															loc_1079_[1](bit32_or(loc_1091_ + 64, 0), loc_1092_, loc_1090_, loc_1094_)
															loc_1094_ = buffer_read_i32(loc_1081_[1], loc_1093_, 36);
															if rt_not_equal_i32(loc_1094_, 0) then
																__spider_scoped_dependencies[6] = loc_1079_;
																loc_1079_[1](bit32_or(loc_1091_ + 72, 0), loc_1094_, loc_1090_, loc_1092_)
																loc_1092_ = 1;
																loc_1079_ = 1;
															else
																__spider_scoped_dependencies[6], loc_1091_ = loc_1091_, __spider_scoped_dependencies[6];
																loc_1091_, loc_1092_ = loc_1092_, loc_1091_;
																loc_1092_, loc_1090_ = loc_1090_, loc_1092_;
																__spider_scoped_dependencies[6] = loc_1079_;
																loc_1092_ = 0;
																loc_1094_ = 9;
																loc_1079_ = loc_1090_;
																loc_1078_ = loc_1091_;
															end
														else
															__spider_scoped_dependencies[6], loc_1091_ = loc_1091_, __spider_scoped_dependencies[6];
															loc_1091_, loc_1094_ = loc_1094_, loc_1091_;
															loc_1094_, loc_1092_ = loc_1092_, loc_1094_;
															loc_1092_, loc_1090_ = loc_1090_, loc_1092_;
															__spider_scoped_dependencies[6] = loc_1079_;
															loc_1092_ = 0;
															loc_1094_ = 8;
															loc_1079_ = loc_1090_;
															loc_1078_ = loc_1091_;
														end
													else
														__spider_scoped_dependencies[6], loc_1091_ = loc_1091_, __spider_scoped_dependencies[6];
														loc_1091_, loc_1094_ = loc_1094_, loc_1091_;
														loc_1094_, loc_1092_ = loc_1092_, loc_1094_;
														loc_1092_, loc_1090_ = loc_1090_, loc_1092_;
														__spider_scoped_dependencies[6] = loc_1079_;
														loc_1092_ = 0;
														loc_1094_ = 7;
														loc_1079_ = loc_1090_;
														loc_1078_ = loc_1091_;
													end
												else
													__spider_scoped_dependencies[6], loc_1091_ = loc_1091_, __spider_scoped_dependencies[6];
													loc_1091_, loc_1094_ = loc_1094_, loc_1091_;
													loc_1094_, loc_1092_ = loc_1092_, loc_1094_;
													loc_1092_, loc_1090_ = loc_1090_, loc_1092_;
													__spider_scoped_dependencies[6] = loc_1079_;
													loc_1092_ = 0;
													loc_1094_ = 6;
													loc_1079_ = loc_1090_;
													loc_1078_ = loc_1091_;
												end
											else
												__spider_scoped_dependencies[6], loc_1091_ = loc_1091_, __spider_scoped_dependencies[6];
												loc_1091_, loc_1094_ = loc_1094_, loc_1091_;
												loc_1094_, loc_1092_ = loc_1092_, loc_1094_;
												loc_1092_, loc_1090_ = loc_1090_, loc_1092_;
												__spider_scoped_dependencies[6] = loc_1079_;
												loc_1092_ = 0;
												loc_1094_ = 5;
												loc_1079_ = loc_1090_;
												loc_1078_ = loc_1091_;
											end
										else
											__spider_scoped_dependencies[6], loc_1091_ = loc_1091_, __spider_scoped_dependencies[6];
											loc_1091_, loc_1094_ = loc_1094_, loc_1091_;
											loc_1094_, loc_1092_ = loc_1092_, loc_1094_;
											loc_1092_, loc_1090_ = loc_1090_, loc_1092_;
											__spider_scoped_dependencies[6] = loc_1079_;
											loc_1092_ = 0;
											loc_1094_ = 4;
											loc_1079_ = loc_1090_;
											loc_1078_ = loc_1091_;
										end
									else
										__spider_scoped_dependencies[6], loc_1091_ = loc_1091_, __spider_scoped_dependencies[6];
										loc_1091_, loc_1094_ = loc_1094_, loc_1091_;
										loc_1094_, loc_1092_ = loc_1092_, loc_1094_;
										loc_1092_, loc_1090_ = loc_1090_, loc_1092_;
										__spider_scoped_dependencies[6] = loc_1079_;
										loc_1092_ = 0;
										loc_1094_ = 3;
										loc_1079_ = loc_1090_;
										loc_1078_ = loc_1091_;
									end
								else
									__spider_scoped_dependencies[6], loc_1091_ = loc_1091_, __spider_scoped_dependencies[6];
									loc_1091_, loc_1094_ = loc_1094_, loc_1091_;
									loc_1094_, loc_1092_ = loc_1092_, loc_1094_;
									loc_1092_, loc_1090_ = loc_1090_, loc_1092_;
									__spider_scoped_dependencies[6] = loc_1079_;
									loc_1092_ = 0;
									loc_1094_ = 2;
									loc_1079_ = loc_1090_;
									loc_1078_ = loc_1091_;
								end
							else
								__spider_scoped_dependencies[6], loc_1091_ = loc_1091_, __spider_scoped_dependencies[6];
								loc_1091_, loc_1094_ = loc_1094_, loc_1091_;
								loc_1094_, loc_1092_ = loc_1092_, loc_1094_;
								loc_1092_, loc_1090_ = loc_1090_, loc_1092_;
								__spider_scoped_dependencies[6] = loc_1079_;
								loc_1092_ = 0;
								loc_1094_ = 1;
								loc_1079_ = loc_1090_;
								loc_1078_ = loc_1091_;
							end
							if rt_not_equal_i32(loc_1092_, 0) then
								loc_1090_ = 3;
							else
								loc_1094_ = rt_shift_left_i32(loc_1094_, 2);
								repeat
									rt_yield_budget = rt_yield_budget - 1
									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
									loc_1095_ = buffer_read_i32(loc_1081_[1], bit32_or(loc_1093_ + loc_1094_, 0), 0);
									if rt_not_equal_i32(loc_1095_, 0) then
										loc_1092_ = 0;
										loc_1095_ = 1;
									else
										loc_1094_ = bit32_or(loc_1094_ + 4, 0);
										if rt_not_equal_i32(loc_1094_, 40) then
											loc_1092_ = 1;
											loc_1095_ = 65535;
										else
											loc_1092_ = 0;
											loc_1095_ = 0;
										end
									end
								until loc_1092_ == 0
								if rt_not_equal_i32(loc_1095_, 0) then
									loc_1090_ = 0;
								else
									loc_1095_ = loc_1079_;
									loc_1090_ = 3;
									loc_1079_ = 1;
								end
							end
						else
							loc_1090_ = loc_1079_;
							loc_1079_ = __spider_scoped_dependencies[6];
							loc_1091_ = loc_1092_;
							loc_1092_ = loc_1093_;
							loc_1093_ = loc_1094_;
							loc_1094_ = loc_1078_;
							__spider_scoped_dependencies[6] = loc_1079_;
							loc_1090_ = 3;
							loc_1079_ = 0;
							loc_1078_ = loc_1094_;
						end
					end
				end
			else
				loc_1090_ = 2;
			end
			if (loc_1090_) >= 0 and (loc_1090_) < 3 then
				if (loc_1090_) < 1 then
					rt_store_i32(loc_1081_, 0, 70852, 28)
					loc_1090_ = 0;
				elseif (loc_1090_) > 1 then
					loc_1090_ = 0;
				else
					rt_store_i32(loc_1081_, 0, 70852, 61)
					loc_1090_ = 0;
				end
			else
				loc_1090_ = 1;
			end
			if not (rt_not_equal_i32(loc_1090_, 0)) then
				loc_1079_ = -1;
			end
			loc_1080_[1] = bit32_or(loc_1082_ + 864, 0);
			return loc_1079_, loc_1078_
		end), "i32,i32,i32,i32,i32->i32")
	end)(module_locals[79], module_locals[94], module_locals[95], module_locals[97], module_locals[98], module_locals[102], module_locals[103], module_locals[114], module_locals[3]);
	module_locals[104] = { nil };
	module_locals[102][1] = (function(loc_1133_, loc_1134_)
		return rt_function_type((function(loc_1135_, loc_1136_, loc_1137_, loc_1138_)
			local loc_1139_, loc_1140_, loc_1141_, loc_1142_, loc_1143_, loc_1144_
			loc_1144_ = bit32_or(loc_1136_ + -9, 0);
			if (loc_1144_) >= 0 and (loc_1144_) < 18 then
				if (loc_1144_) < 9 then
					if (loc_1144_) < 4 then
						if (loc_1144_) < 2 then
							if (loc_1144_) < 1 then
								loc_1139_ = loc_1138_;
								loc_1140_ = loc_1134_;
								loc_1141_ = loc_1133_;
								loc_1142_ = loc_1135_;
								loc_1143_ = loc_1137_;
								loc_1144_ = buffer_read_i32(loc_1140_[1], loc_1143_, 0);
								rt_store_i32(loc_1140_, loc_1143_, 0, bit32_or(loc_1144_ + 4, 0))
								loc_1144_ = buffer_read_i32(loc_1140_[1], loc_1144_, 0);
								rt_store_i32(loc_1140_, loc_1142_, 0, loc_1144_)
								loc_1142_ = 0;
							else
								loc_1139_ = loc_1138_;
								loc_1140_ = loc_1134_;
								loc_1141_ = loc_1133_;
								loc_1142_ = loc_1135_;
								loc_1143_ = loc_1137_;
								loc_1144_ = buffer_read_i32(loc_1140_[1], loc_1143_, 0);
								rt_store_i32(loc_1140_, loc_1143_, 0, bit32_or(loc_1144_ + 4, 0))
								loc_1144_ = rt_load_i64_from_s32(loc_1140_, loc_1144_, 0);
								rt_store_i64(loc_1140_, loc_1142_, 0, loc_1144_)
								loc_1142_ = 1;
							end
						elseif (loc_1144_) > 2 then
							loc_1139_ = loc_1138_;
							loc_1140_ = loc_1134_;
							loc_1141_ = loc_1133_;
							loc_1142_ = loc_1135_;
							loc_1143_ = loc_1137_;
							loc_1144_ = buffer_read_i32(loc_1140_[1], loc_1143_, 0);
							loc_1144_ = rt_and_i32(bit32_or(loc_1144_ + 7, 0), -8);
							rt_store_i32(loc_1140_, loc_1143_, 0, bit32_or(loc_1144_ + 8, 0))
							loc_1144_ = rt_load_i64(loc_1140_, loc_1144_, 0);
							rt_store_i64(loc_1140_, loc_1142_, 0, loc_1144_)
							loc_1142_ = 1;
						else
							loc_1139_ = loc_1138_;
							loc_1140_ = loc_1134_;
							loc_1141_ = loc_1133_;
							loc_1142_ = loc_1135_;
							loc_1143_ = loc_1137_;
							loc_1144_ = buffer_read_i32(loc_1140_[1], loc_1143_, 0);
							rt_store_i32(loc_1140_, loc_1143_, 0, bit32_or(loc_1144_ + 4, 0))
							loc_1144_ = rt_load_i64_from_u32(loc_1140_, loc_1144_, 0);
							rt_store_i64(loc_1140_, loc_1142_, 0, loc_1144_)
							loc_1142_ = 1;
						end
					elseif (loc_1144_) > 4 then
						if (loc_1144_) < 7 then
							if (loc_1144_) < 6 then
								loc_1139_ = loc_1138_;
								loc_1140_ = loc_1134_;
								loc_1141_ = loc_1133_;
								loc_1142_ = loc_1135_;
								loc_1143_ = loc_1137_;
								loc_1144_ = buffer_read_i32(loc_1140_[1], loc_1143_, 0);
								rt_store_i32(loc_1140_, loc_1143_, 0, bit32_or(loc_1144_ + 4, 0))
								loc_1144_ = rt_load_i64_from_u32(loc_1140_, loc_1144_, 0);
								rt_store_i64(loc_1140_, loc_1142_, 0, loc_1144_)
								loc_1142_ = 1;
							else
								loc_1139_ = loc_1138_;
								loc_1140_ = loc_1134_;
								loc_1141_ = loc_1133_;
								loc_1142_ = loc_1135_;
								loc_1143_ = loc_1137_;
								loc_1144_ = buffer_read_i32(loc_1140_[1], loc_1143_, 0);
								rt_store_i32(loc_1140_, loc_1143_, 0, bit32_or(loc_1144_ + 4, 0))
								loc_1144_ = rt_load_i64_from_s16(loc_1140_, loc_1144_, 0);
								rt_store_i64(loc_1140_, loc_1142_, 0, loc_1144_)
								loc_1142_ = 1;
							end
						elseif (loc_1144_) > 7 then
							loc_1139_ = loc_1138_;
							loc_1140_ = loc_1134_;
							loc_1141_ = loc_1133_;
							loc_1142_ = loc_1135_;
							loc_1143_ = loc_1137_;
							loc_1144_ = buffer_read_i32(loc_1140_[1], loc_1143_, 0);
							rt_store_i32(loc_1140_, loc_1143_, 0, bit32_or(loc_1144_ + 4, 0))
							loc_1144_ = rt_load_i64_from_s8(loc_1140_, loc_1144_, 0);
							rt_store_i64(loc_1140_, loc_1142_, 0, loc_1144_)
							loc_1142_ = 1;
						else
							loc_1139_ = loc_1138_;
							loc_1140_ = loc_1134_;
							loc_1141_ = loc_1133_;
							loc_1142_ = loc_1135_;
							loc_1143_ = loc_1137_;
							loc_1144_ = buffer_read_i32(loc_1140_[1], loc_1143_, 0);
							rt_store_i32(loc_1140_, loc_1143_, 0, bit32_or(loc_1144_ + 4, 0))
							loc_1144_ = rt_load_i64_from_u16(loc_1140_, loc_1144_, 0);
							rt_store_i64(loc_1140_, loc_1142_, 0, loc_1144_)
							loc_1142_ = 1;
						end
					else
						loc_1139_ = loc_1138_;
						loc_1140_ = loc_1134_;
						loc_1141_ = loc_1133_;
						loc_1142_ = loc_1135_;
						loc_1143_ = loc_1137_;
						loc_1144_ = buffer_read_i32(loc_1140_[1], loc_1143_, 0);
						rt_store_i32(loc_1140_, loc_1143_, 0, bit32_or(loc_1144_ + 4, 0))
						loc_1144_ = rt_load_i64_from_s32(loc_1140_, loc_1144_, 0);
						rt_store_i64(loc_1140_, loc_1142_, 0, loc_1144_)
						loc_1142_ = 1;
					end
				elseif (loc_1144_) > 9 then
					if (loc_1144_) < 14 then
						if (loc_1144_) < 12 then
							if (loc_1144_) < 11 then
								loc_1139_ = loc_1138_;
								loc_1140_ = loc_1134_;
								loc_1141_ = loc_1133_;
								loc_1142_ = loc_1135_;
								loc_1143_ = loc_1137_;
								loc_1144_ = buffer_read_i32(loc_1140_[1], loc_1143_, 0);
								loc_1144_ = rt_and_i32(bit32_or(loc_1144_ + 7, 0), -8);
								rt_store_i32(loc_1140_, loc_1143_, 0, bit32_or(loc_1144_ + 8, 0))
								loc_1144_ = rt_load_i64(loc_1140_, loc_1144_, 0);
								rt_store_i64(loc_1140_, loc_1142_, 0, loc_1144_)
								loc_1142_ = 1;
							else
								loc_1139_ = loc_1138_;
								loc_1140_ = loc_1134_;
								loc_1141_ = loc_1133_;
								loc_1142_ = loc_1135_;
								loc_1143_ = loc_1137_;
								loc_1144_ = buffer_read_i32(loc_1140_[1], loc_1143_, 0);
								rt_store_i32(loc_1140_, loc_1143_, 0, bit32_or(loc_1144_ + 4, 0))
								loc_1144_ = rt_load_i64_from_u32(loc_1140_, loc_1144_, 0);
								rt_store_i64(loc_1140_, loc_1142_, 0, loc_1144_)
								loc_1142_ = 1;
							end
						elseif (loc_1144_) > 12 then
							loc_1139_ = loc_1138_;
							loc_1140_ = loc_1134_;
							loc_1141_ = loc_1133_;
							loc_1142_ = loc_1135_;
							loc_1143_ = loc_1137_;
							loc_1144_ = buffer_read_i32(loc_1140_[1], loc_1143_, 0);
							loc_1144_ = rt_and_i32(bit32_or(loc_1144_ + 7, 0), -8);
							rt_store_i32(loc_1140_, loc_1143_, 0, bit32_or(loc_1144_ + 8, 0))
							loc_1144_ = rt_load_i64(loc_1140_, loc_1144_, 0);
							rt_store_i64(loc_1140_, loc_1142_, 0, loc_1144_)
							loc_1142_ = 1;
						else
							loc_1139_ = loc_1138_;
							loc_1140_ = loc_1134_;
							loc_1141_ = loc_1133_;
							loc_1142_ = loc_1135_;
							loc_1143_ = loc_1137_;
							loc_1144_ = buffer_read_i32(loc_1140_[1], loc_1143_, 0);
							loc_1144_ = rt_and_i32(bit32_or(loc_1144_ + 7, 0), -8);
							rt_store_i32(loc_1140_, loc_1143_, 0, bit32_or(loc_1144_ + 8, 0))
							loc_1144_ = rt_load_i64(loc_1140_, loc_1144_, 0);
							rt_store_i64(loc_1140_, loc_1142_, 0, loc_1144_)
							loc_1142_ = 1;
						end
					elseif (loc_1144_) > 14 then
						if (loc_1144_) < 16 then
							loc_1139_ = loc_1138_;
							loc_1140_ = loc_1134_;
							loc_1141_ = loc_1133_;
							loc_1142_ = loc_1135_;
							loc_1143_ = loc_1137_;
							loc_1144_ = buffer_read_i32(loc_1140_[1], loc_1143_, 0);
							rt_store_i32(loc_1140_, loc_1143_, 0, bit32_or(loc_1144_ + 4, 0))
							loc_1144_ = rt_load_i64_from_u32(loc_1140_, loc_1144_, 0);
							rt_store_i64(loc_1140_, loc_1142_, 0, loc_1144_)
							loc_1142_ = 1;
						elseif (loc_1144_) > 16 then
							loc_1139_ = loc_1138_;
							loc_1140_ = loc_1134_;
							loc_1141_ = loc_1137_;
							loc_1142_ = loc_1133_;
							loc_1143_ = loc_1135_;
							loc_1141_ = loc_1142_;
							loc_1143_ = loc_1139_;
							loc_1142_[1](loc_1143_)
							loc_1142_ = 1;
							loc_1143_ = error('unreachable code');
						else
							loc_1139_ = loc_1138_;
							loc_1140_ = loc_1134_;
							loc_1141_ = loc_1133_;
							loc_1142_ = loc_1135_;
							loc_1144_ = loc_1137_;
							loc_1143_ = buffer_read_i32(loc_1140_[1], loc_1144_, 0);
							loc_1143_ = rt_and_i32(bit32_or(loc_1143_ + 7, 0), -8);
							rt_store_i32(loc_1140_, loc_1144_, 0, bit32_or(loc_1143_ + 8, 0))
							loc_1143_ = rt_load_f64(loc_1140_, loc_1143_, 0);
							rt_store_f64(loc_1140_, loc_1142_, 0, loc_1143_)
							loc_1142_ = 1;
						end
					else
						loc_1139_ = loc_1138_;
						loc_1140_ = loc_1134_;
						loc_1141_ = loc_1133_;
						loc_1142_ = loc_1135_;
						loc_1143_ = loc_1137_;
						loc_1144_ = buffer_read_i32(loc_1140_[1], loc_1143_, 0);
						rt_store_i32(loc_1140_, loc_1143_, 0, bit32_or(loc_1144_ + 4, 0))
						loc_1144_ = rt_load_i64_from_s32(loc_1140_, loc_1144_, 0);
						rt_store_i64(loc_1140_, loc_1142_, 0, loc_1144_)
						loc_1142_ = 1;
					end
				else
					loc_1139_ = loc_1138_;
					loc_1140_ = loc_1134_;
					loc_1141_ = loc_1133_;
					loc_1142_ = loc_1135_;
					loc_1143_ = loc_1137_;
					loc_1144_ = buffer_read_i32(loc_1140_[1], loc_1143_, 0);
					rt_store_i32(loc_1140_, loc_1143_, 0, bit32_or(loc_1144_ + 4, 0))
					loc_1144_ = rt_load_i64_from_u8(loc_1140_, loc_1144_, 0);
					rt_store_i64(loc_1140_, loc_1142_, 0, loc_1144_)
					loc_1142_ = 1;
				end
			else
				loc_1139_ = loc_1138_;
				loc_1140_ = loc_1134_;
				loc_1141_ = loc_1133_;
				loc_1142_ = loc_1135_;
				loc_1143_ = loc_1137_;
				loc_1142_ = 0;
			end
			if rt_not_equal_i32(loc_1142_, 0) then
			end
			return loc_1139_
		end), "i32,i32,i32->")
	end)(module_locals[104], module_locals[3]);
	module_locals[103][1] = (function(loc_1145_, loc_1146_, loc_1147_)
		return rt_function_type((function(loc_1148_, loc_1149_, loc_1150_, loc_1151_, loc_1152_, loc_1153_)
			local loc_1154_, loc_1155_, loc_1156_, loc_1157_, loc_1158_, loc_1159_, loc_1160_, loc_1161_, loc_1162_, loc_1163_, loc_1164_
			loc_1164_ = loc_1146_[1];
			loc_1155_ = loc_1146_;
			loc_1157_ = bit32_or(loc_1164_ - 256, 0);
			loc_1155_[1] = loc_1157_;
			if rt_less_than_equal_s32(loc_1150_, loc_1151_) then
				loc_1154_ = loc_1153_;
				loc_1156_ = loc_1147_;
				loc_1158_ = loc_1145_;
				loc_1159_ = loc_1148_;
				loc_1160_ = loc_1149_;
				loc_1161_ = loc_1150_;
				loc_1162_ = loc_1151_;
				loc_1163_ = loc_1152_;
			else
				loc_1154_ = loc_1153_;
				loc_1156_ = loc_1147_;
				loc_1158_ = loc_1145_;
				loc_1159_ = loc_1148_;
				loc_1160_ = loc_1149_;
				loc_1161_ = loc_1150_;
				loc_1162_ = loc_1151_;
				loc_1163_ = loc_1152_;
				if rt_not_equal_i32(rt_and_i32(loc_1163_, 73728), 0) then
					loc_1163_ = loc_1159_;
					loc_1160_, loc_1162_ = loc_1162_, loc_1160_;
				else
					loc_1163_ = loc_1159_;
					loc_1160_, loc_1162_ = loc_1162_, loc_1160_;
					loc_1159_ = bit32_or(loc_1161_ - loc_1160_, 0);
					loc_1161_ = (rt_less_than_u32(loc_1159_, 256) and 1 or 0);
					loc_1164_ = 256;
					if rt_not_equal_i32(loc_1161_, 0) then
						loc_1160_ = loc_1162_;
						loc_1162_ = loc_1159_;
					else
						loc_1160_ = loc_1162_;
						loc_1162_ = loc_1159_;
						loc_1159_ = loc_1164_;
					end
					if not (rt_equal_i32(loc_1159_, 0)) then
						rt_memory_fill(loc_1156_, loc_1157_, loc_1160_, loc_1159_)
					end
					if not (rt_not_equal_i32(loc_1161_, 0)) then
						repeat
							rt_yield_budget = rt_yield_budget - 1
							if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
							loc_1161_ = rt_load_i32_from_u8(loc_1156_, loc_1163_, 0);
							if not (rt_not_equal_i32(rt_and_i32(loc_1161_, 32), 0)) then
								loc_1160_ = loc_1158_;
								loc_1158_ = loc_1160_;
								loc_1161_ = loc_1154_;
								loc_1161_ = loc_1160_[1](loc_1157_, 256, loc_1163_, loc_1161_)
							end
							loc_1161_ = bit32_or(loc_1162_ + -256, 0);
							loc_1162_ = loc_1161_;
						until not (rt_greater_than_u32(loc_1161_, 255))
					end
					loc_1161_ = rt_load_i32_from_u8(loc_1156_, loc_1163_, 0);
					if not (rt_not_equal_i32(rt_and_i32(loc_1161_, 32), 0)) then
						loc_1160_ = loc_1158_;
						loc_1158_ = loc_1160_;
						loc_1161_ = loc_1154_;
						loc_1163_ = loc_1160_[1](loc_1157_, loc_1162_, loc_1163_, loc_1161_)
					end
				end
			end
			loc_1155_[1] = bit32_or(loc_1157_ + 256, 0);
			return loc_1154_
		end), "i32,i32,i32,i32,i32->")
	end)(module_locals[79], module_locals[114], module_locals[3]);
	module_locals[104][1] = (function(loc_1165_, loc_1166_)
		return rt_function_type((function(loc_1167_)
			local loc_1168_, loc_1169_
			loc_1169_ = loc_1167_;
			loc_1168_ = loc_1165_[1](1187, 6592, loc_1169_)
			loc_1166_[1](loc_1169_)
			loc_1169_ = error('unreachable code');
			return loc_1168_
		end), "->")
	end)(module_locals[81], module_locals[99]);
	module_locals[105] = { nil };
	module_locals[105][1] = (function(loc_1170_, loc_1171_)
		return rt_function_type((function(loc_1172_, loc_1173_)
			local loc_1174_, loc_1175_, loc_1176_, loc_1177_, loc_1178_
			if rt_not_equal_i32(loc_1172_, 0) then
				loc_1174_ = loc_1173_;
				loc_1175_ = loc_1172_;
				loc_1176_ = loc_1171_;
				loc_1177_ = loc_1170_;
				if rt_not_equal_i32(rt_and_i32(loc_1175_, 65535), 0) then
					loc_1178_ = 0;
				else
					if rt_less_than_equal_s32(loc_1175_, -1) then
						loc_1178_ = 0;
					else
						loc_1178_ = rt_shift_right_u32(loc_1175_, 16);
						if rt_less_than_equal_u32(loc_1178_, 65535) then
							loc_1175_ = rt_memory_grow(loc_1176_, rt_multiply_i32(loc_1178_, 65536));
							if not (rt_equal_i32(loc_1175_, -1)) then
								loc_1178_ = rt_divide_u32(loc_1175_, 65536);
								loc_1175_ = loc_1178_;
							end
						else
							loc_1175_ = -1;
						end
						if rt_not_equal_i32(loc_1175_, -1) then
							loc_1178_ = 1;
							loc_1175_ = rt_shift_left_i32(loc_1175_, 16);
						else
							loc_1178_ = loc_1175_;
							rt_store_i32(loc_1176_, 0, 70852, 48)
							loc_1178_ = 1;
							loc_1175_ = -1;
						end
					end
				end
				if not (rt_not_equal_i32(loc_1178_, 0)) then
					loc_1178_ = loc_1174_;
					loc_1174_ = loc_1177_;
					loc_1177_ = loc_1174_;
					loc_1174_[1](loc_1178_)
					loc_1178_ = error('unreachable code');
				end
			else
				loc_1174_ = loc_1173_;
				loc_1176_ = loc_1171_;
				loc_1177_ = loc_1170_;
				loc_1178_ = loc_1172_;
				loc_1178_ = rt_memory_size(loc_1176_);
				loc_1178_ = rt_divide_u32(loc_1178_, 65536);
				loc_1175_ = rt_shift_left_i32(loc_1178_, 16);
			end
			return loc_1175_, loc_1174_
		end), "i32->i32")
	end)(module_locals[99], module_locals[3]);
	module_locals[107] = { nil };
	module_locals[106][1] = (function(loc_1179_)
		return rt_function_type((function(loc_1180_, loc_1181_)
			local loc_1182_, loc_1183_
			loc_1183_ = loc_1181_;
			loc_1183_ = loc_1179_[1](loc_1180_, loc_1183_)
			return loc_1183_, loc_1182_
		end), "i32->i32")
	end)(module_locals[107]);
	module_locals[108] = { nil };
	module_locals[107][1] = (function(loc_1184_, loc_1185_, loc_1186_, loc_1187_)
		return rt_function_type((function(loc_1188_, loc_1189_)
			local loc_1190_, loc_1191_, loc_1192_, loc_1193_, loc_1194_, loc_1195_, loc_1196_, loc_1197_, loc_1198_, loc_1199_, loc_1200_, loc_1201_, loc_1202_, loc_1203_, loc_1204_, loc_1205_, loc_1206_, loc_1207_, loc_1208_, loc_1209_
			loc_1209_ = loc_1186_[1];
			loc_1192_ = loc_1186_;
			loc_1198_ = bit32_or(loc_1209_ - 16, 0);
			loc_1192_[1] = loc_1198_;
			loc_1199_ = buffer_read_i32(loc_1187_[1], 0, 71988);
			loc_1193_ = loc_1187_;
			loc_1196_ = 0;
			loc_1197_ = 0;
			loc_1200_ = 0;
			loc_1201_ = 0;
			loc_1202_ = 0;
			loc_1203_ = 0;
			loc_1204_ = 0;
			if rt_not_equal_i32(loc_1199_, 0) then
				loc_1190_ = loc_1189_;
				loc_1191_ = loc_1188_;
				loc_1194_ = loc_1184_;
				loc_1195_ = loc_1185_;
				loc_1209_ = 0;
			else
				loc_1190_ = loc_1189_;
				loc_1191_ = loc_1188_;
				loc_1194_ = loc_1184_;
				loc_1195_ = loc_1185_;
				loc_1209_ = buffer_read_i32(loc_1193_[1], 0, 72436);
				if not (rt_not_equal_i32(loc_1209_, 0)) then
					rt_store_i64(loc_1193_, 0, 72448, into_bits_i64(4294967295, 4294967295))
					rt_store_i64(loc_1193_, 0, 72440, into_bits_i64(65536, 65536))
					loc_1209_ = rt_exclusive_or_i32(rt_and_i32(bit32_or(loc_1198_ + 8, 0), -16), 1431655768);
					rt_store_i32(loc_1193_, 0, 72436, loc_1209_)
					rt_store_i32(loc_1193_, 0, 72456, 0)
					rt_store_i32(loc_1193_, 0, 72408, 0)
				end
				if rt_less_than_u32(196608, 138000) then
					loc_1209_ = 1;
					loc_1208_ = error('unreachable code');
				else
					loc_1208_ = loc_1199_;
					loc_1199_ = 0;
					if rt_less_than_u32(bit32_or(196608 - 138000, 0), 89) then
						loc_1209_ = 0;
					else
						loc_1207_ = loc_1200_;
						loc_1208_ = loc_1199_;
						rt_store_i32(loc_1193_, 0, 72412, 138000)
						rt_store_i32(loc_1193_, 0, 71980, 138000)
						rt_store_i32(loc_1193_, 0, 72000, loc_1209_)
						rt_store_i32(loc_1193_, 0, 71996, -1)
						loc_1209_ = bit32_or(196608 - 138000, 0);
						rt_store_i32(loc_1193_, 0, 72416, loc_1209_)
						rt_store_i32(loc_1193_, 0, 72400, loc_1209_)
						rt_store_i32(loc_1193_, 0, 72396, loc_1209_)
						loc_1209_ = 0;
						repeat
							rt_yield_budget = rt_yield_budget - 1
							if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
							loc_1208_ = bit32_or(loc_1209_ + 72012, 0);
							rt_store_i32(loc_1193_, bit32_or(loc_1209_ + 72024, 0), 0, loc_1208_)
							loc_1207_ = bit32_or(loc_1209_ + 72004, 0);
							rt_store_i32(loc_1193_, loc_1208_, 0, loc_1207_)
							rt_store_i32(loc_1193_, bit32_or(loc_1209_ + 72016, 0), 0, loc_1207_)
							loc_1207_ = bit32_or(loc_1209_ + 72020, 0);
							rt_store_i32(loc_1193_, bit32_or(loc_1209_ + 72032, 0), 0, loc_1207_)
							rt_store_i32(loc_1193_, loc_1207_, 0, loc_1208_)
							loc_1208_ = bit32_or(loc_1209_ + 72028, 0);
							rt_store_i32(loc_1193_, bit32_or(loc_1209_ + 72040, 0), 0, loc_1208_)
							rt_store_i32(loc_1193_, loc_1208_, 0, loc_1207_)
							rt_store_i32(loc_1193_, bit32_or(loc_1209_ + 72036, 0), 0, loc_1208_)
							loc_1208_ = bit32_or(loc_1209_ + 32, 0);
							loc_1209_ = loc_1208_;
						until not (rt_not_equal_i32(loc_1208_, 256))
						rt_store_i32(loc_1193_, bit32_or(196608 + -52, 0), 0, 56)
						loc_1209_ = buffer_read_i32(loc_1193_[1], 0, 72452);
						rt_store_i32(loc_1193_, 0, 71992, loc_1209_)
						loc_1209_ = rt_and_i32(bit32_or(-8 - 138000, 0), 15);
						loc_1199_ = bit32_or(138000 + loc_1209_, 0);
						rt_store_i32(loc_1193_, 0, 71988, loc_1199_)
						loc_1200_ = bit32_or(bit32_or(bit32_or(196608 - 138000, 0) - loc_1209_, 0) + -56, 0);
						rt_store_i32(loc_1193_, 0, 71976, loc_1200_)
						rt_store_i32(loc_1193_, loc_1199_, 4, rt_or_i32(loc_1200_, 1))
						loc_1209_ = 0;
					end
				end
			end
			if not (rt_not_equal_i32(loc_1209_, 0)) then
				if rt_greater_than_u32(loc_1191_, 236) then
					loc_1205_ = loc_1202_;
					loc_1202_ = loc_1197_;
					loc_1206_ = loc_1201_;
					loc_1201_ = loc_1199_;
					loc_1207_ = loc_1191_;
					loc_1191_ = loc_1200_;
					loc_1200_ = loc_1204_;
					loc_1204_ = loc_1198_;
					loc_1208_ = loc_1203_;
					loc_1203_ = loc_1196_;
					loc_1200_ = -1;
					if rt_greater_than_u32(loc_1207_, -65) then
						loc_1207_ = 0;
					else
						loc_1208_ = loc_1191_;
						loc_1199_ = buffer_read_i32(loc_1193_[1], 0, 71968);
						loc_1191_ = bit32_or(loc_1207_ + 19, 0);
						loc_1200_ = rt_and_i32(loc_1191_, -16);
						if rt_equal_i32(loc_1199_, 0) then
							loc_1207_ = 0;
						else
							loc_1208_ = 31;
							if rt_greater_than_u32(loc_1207_, 16777196) then
								loc_1198_ = loc_1199_;
								loc_1199_ = loc_1200_;
								loc_1207_ = loc_1191_;
							else
								loc_1198_ = loc_1199_;
								loc_1207_ = loc_1200_;
								loc_1200_ = loc_1208_;
								loc_1208_ = loc_1191_;
								loc_1199_ = loc_1207_;
								loc_1208_ = rt_leading_zeroes_i32(rt_shift_right_u32(loc_1208_, 8));
								loc_1208_ = bit32_or(bit32_or(rt_and_i32(rt_shift_right_u32(loc_1207_, bit32_or(38 - loc_1208_, 0)), 1) - rt_shift_left_i32(loc_1208_, 1), 0) + 62, 0);
							end
							loc_1197_ = buffer_read_i32(loc_1193_[1], rt_shift_left_i32(loc_1208_, 2), 72268);
							loc_1207_ = bit32_or(0 - loc_1199_, 0);
							if rt_not_equal_i32(loc_1197_, 0) then
								loc_1191_ = 0;
								loc_1205_ = 0;
								loc_1196_ = bit32_or(25 - rt_shift_right_u32(loc_1208_, 1), 0);
								if rt_equal_i32(loc_1208_, 31) then
									loc_1200_ = loc_1199_;
								else
									loc_1200_ = loc_1199_;
									loc_1205_ = loc_1196_;
								end
								loc_1205_ = rt_shift_left_i32(loc_1199_, loc_1205_);
								loc_1199_ = 0;
								repeat
									rt_yield_budget = rt_yield_budget - 1
									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
									loc_1206_ = buffer_read_i32(loc_1193_[1], loc_1197_, 4);
									loc_1206_ = bit32_or(rt_and_i32(loc_1206_, -8) - loc_1200_, 0);
									if rt_greater_than_equal_u32(loc_1206_, loc_1207_) then
										loc_1196_ = loc_1203_;
										loc_1203_ = 0;
									else
										loc_1196_ = loc_1203_;
										loc_1203_ = loc_1199_;
										if rt_not_equal_i32(loc_1206_, 0) then
											loc_1199_ = loc_1197_;
											loc_1207_ = loc_1206_;
											loc_1203_ = 0;
										else
											loc_1199_ = loc_1197_;
											loc_1203_ = loc_1196_;
											loc_1207_ = loc_1206_;
											loc_1203_ = 1;
											loc_1196_ = 0;
											loc_1202_ = 0;
										end
									end
									if not (rt_not_equal_i32(loc_1203_, 0)) then
										loc_1203_ = loc_1202_;
										loc_1202_ = loc_1206_;
										loc_1206_ = loc_1196_;
										loc_1202_ = buffer_read_i32(loc_1193_[1], loc_1197_, 20);
										loc_1197_ = buffer_read_i32(loc_1193_[1], bit32_or(loc_1197_ + rt_and_i32(rt_shift_right_u32(loc_1205_, 29), 4), 0), 16);
										if rt_equal_i32(loc_1202_, loc_1197_) then
											loc_1203_ = loc_1191_;
											loc_1206_ = loc_1202_;
										else
											loc_1196_ = loc_1191_;
											loc_1203_ = loc_1191_;
											loc_1206_ = loc_1202_;
											loc_1191_ = loc_1202_;
										end
										if not (rt_not_equal_i32(loc_1206_, 0)) then
											loc_1202_ = loc_1191_;
											loc_1191_ = loc_1203_;
										end
										loc_1205_ = rt_shift_left_i32(loc_1205_, 1);
										if rt_not_equal_i32(loc_1197_, 0) then
											loc_1196_ = 1;
											loc_1202_ = 65535;
										else
											loc_1196_ = 0;
											loc_1202_ = 1;
										end
									end
									loc_1203_ = loc_1196_;
								until loc_1196_ == 0
								if rt_not_equal_i32(loc_1202_, 0) then
									loc_1197_ = 0;
								else
									loc_1196_ = loc_1199_;
									loc_1199_ = loc_1197_;
									loc_1197_ = loc_1191_;
									loc_1197_ = 1;
									loc_1207_ = 0;
									loc_1191_ = loc_1199_;
								end
							else
								loc_1200_ = loc_1197_;
								loc_1197_ = 0;
								loc_1191_ = 0;
								loc_1200_ = loc_1199_;
								loc_1199_ = 0;
							end
							if rt_not_equal_i32(loc_1197_, 0) then
								loc_1208_ = 0;
							else
								if rt_not_equal_i32(rt_or_i32(loc_1191_, loc_1199_), 0) then
									loc_1208_ = 0;
								else
									loc_1197_ = loc_1199_;
									loc_1199_ = loc_1191_;
									loc_1208_ = rt_shift_left_i32(2, loc_1208_);
									loc_1191_ = rt_and_i32(rt_or_i32(loc_1208_, bit32_or(0 - loc_1208_, 0)), loc_1198_);
									loc_1199_ = 0;
									if rt_equal_i32(loc_1191_, 0) then
										loc_1208_ = 1;
									else
										loc_1191_ = buffer_read_i32(loc_1193_[1], rt_shift_left_i32(rt_trailing_zeroes_i32(loc_1191_), 2), 72268);
										loc_1208_ = 0;
									end
								end
								if rt_not_equal_i32(loc_1208_, 0) then
									loc_1208_ = 2;
								else
									if rt_equal_i32(loc_1191_, 0) then
										loc_1208_ = 1;
									else
										loc_1208_ = 0;
									end
								end
							end
							if (loc_1208_) >= 0 and (loc_1208_) < 2 then
								if (loc_1208_) < 1 then
									repeat
										rt_yield_budget = rt_yield_budget - 1
										if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
										loc_1208_ = loc_1206_;
										loc_1206_ = loc_1205_;
										loc_1206_ = buffer_read_i32(loc_1193_[1], loc_1191_, 4);
										loc_1208_ = buffer_read_i32(loc_1193_[1], loc_1191_, 16);
										loc_1206_ = bit32_or(rt_and_i32(loc_1206_, -8) - loc_1200_, 0);
										loc_1205_ = (rt_less_than_u32(loc_1206_, loc_1207_) and 1 or 0);
										if rt_not_equal_i32(loc_1208_, 0) then
											loc_1196_ = loc_1207_;
											loc_1197_ = loc_1199_;
											loc_1199_ = loc_1191_;
											loc_1207_ = loc_1206_;
										else
											loc_1196_ = loc_1207_;
											loc_1197_ = loc_1199_;
											loc_1199_ = loc_1191_;
											loc_1207_ = loc_1206_;
											loc_1208_ = buffer_read_i32(loc_1193_[1], loc_1199_, 20);
										end
										if rt_not_equal_i32(loc_1205_, 0) then
											loc_1206_ = loc_1207_;
										else
											loc_1206_ = loc_1207_;
											loc_1207_ = loc_1196_;
										end
										if not (rt_not_equal_i32(loc_1205_, 0)) then
											loc_1199_ = loc_1197_;
										end
										loc_1191_ = loc_1208_;
									until loc_1208_ == 0
									loc_1208_ = 0;
								else
									loc_1208_ = 0;
								end
							else
								loc_1208_ = 1;
							end
							if rt_not_equal_i32(loc_1208_, 0) then
								loc_1207_ = 0;
							else
								if rt_equal_i32(loc_1199_, 0) then
									loc_1207_ = 0;
								else
									loc_1208_ = buffer_read_i32(loc_1193_[1], 0, 71972);
									if rt_greater_than_equal_u32(loc_1207_, bit32_or(loc_1208_ - loc_1200_, 0)) then
										loc_1207_ = 0;
									else
										loc_1197_ = loc_1205_;
										loc_1208_ = loc_1191_;
										loc_1208_ = buffer_read_i32(loc_1193_[1], loc_1199_, 24);
										loc_1205_ = buffer_read_i32(loc_1193_[1], loc_1199_, 12);
										if rt_equal_i32(loc_1205_, loc_1199_) then
											loc_1196_ = loc_1207_;
											loc_1207_ = loc_1206_;
											loc_1206_ = loc_1199_;
											loc_1199_ = loc_1208_;
											loc_1197_, loc_1198_ = loc_1198_, loc_1197_;
											loc_1208_ = buffer_read_i32(loc_1193_[1], loc_1206_, 20);
											if rt_equal_i32(loc_1208_, 0) then
												loc_1208_ = buffer_read_i32(loc_1193_[1], loc_1206_, 16);
												if rt_equal_i32(loc_1208_, 0) then
													loc_1191_ = 1;
													loc_1205_ = 0;
												else
													loc_1191_ = 0;
													loc_1198_ = bit32_or(loc_1206_ + 16, 0);
												end
											else
												loc_1191_ = 0;
												loc_1198_ = bit32_or(loc_1206_ + 20, 0);
											end
											if not (rt_not_equal_i32(loc_1191_, 0)) then
												repeat
													rt_yield_budget = rt_yield_budget - 1
													if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
													loc_1203_, loc_1207_ = loc_1207_, loc_1203_;
													loc_1207_, loc_1205_ = loc_1205_, loc_1207_;
													loc_1205_, loc_1208_ = loc_1208_, loc_1205_;
													loc_1208_ = buffer_read_i32(loc_1193_[1], loc_1205_, 20);
													loc_1207_ = bit32_or(loc_1205_ + 20, 0);
													if rt_not_equal_i32(loc_1208_, 0) then
														loc_1203_ = loc_1202_;
														loc_1198_, loc_1207_ = loc_1207_, loc_1198_;
														loc_1191_ = 1;
														loc_1202_ = 65535;
													else
														loc_1203_ = loc_1202_;
														loc_1202_ = loc_1207_;
														loc_1207_ = loc_1198_;
														loc_1208_ = buffer_read_i32(loc_1193_[1], loc_1205_, 16);
														loc_1198_ = bit32_or(loc_1205_ + 16, 0);
														if rt_not_equal_i32(loc_1208_, 0) then
															loc_1191_ = 1;
															loc_1202_ = 65535;
														else
															loc_1191_ = 0;
															loc_1202_ = loc_1203_;
														end
													end
													loc_1203_ = loc_1191_;
												until loc_1191_ == 0
												rt_store_i32(loc_1193_, loc_1207_, 0, 0)
											end
										else
											loc_1196_ = loc_1207_;
											loc_1207_ = loc_1206_;
											loc_1206_ = loc_1199_;
											loc_1199_ = loc_1208_;
											loc_1208_ = loc_1197_;
											loc_1197_ = loc_1198_;
											loc_1208_ = buffer_read_i32(loc_1193_[1], loc_1206_, 8);
											rt_store_i32(loc_1193_, loc_1208_, 12, loc_1205_)
											rt_store_i32(loc_1193_, loc_1205_, 8, loc_1208_)
										end
										if not (rt_equal_i32(loc_1199_, 0)) then
											loc_1191_ = buffer_read_i32(loc_1193_[1], loc_1206_, 28);
											loc_1198_ = rt_shift_left_i32(loc_1191_, 2);
											loc_1208_ = buffer_read_i32(loc_1193_[1], loc_1198_, 72268);
											if rt_not_equal_i32(loc_1206_, loc_1208_) then
												loc_1198_ = buffer_read_i32(loc_1193_[1], loc_1199_, 16);
												if rt_not_equal_i32(loc_1198_, loc_1206_) then
													rt_store_i32(loc_1193_, loc_1199_, 20, loc_1205_)
												else
													rt_store_i32(loc_1193_, loc_1199_, 16, loc_1205_)
												end
												if rt_equal_i32(loc_1205_, 0) then
													loc_1198_ = 1;
												else
													loc_1198_ = 0;
												end
											else
												rt_store_i32(loc_1193_, bit32_or(loc_1198_ + 72268, 0), 0, loc_1205_)
												if rt_not_equal_i32(loc_1205_, 0) then
													loc_1198_ = loc_1191_;
													loc_1198_ = 0;
												else
													loc_1198_ = loc_1191_;
													loc_1197_ = rt_and_i32(loc_1197_, rt_rotate_left_i32(-2, loc_1198_));
													rt_store_i32(loc_1193_, 0, 71968, loc_1197_)
													loc_1198_ = 1;
												end
											end
											if not (rt_not_equal_i32(loc_1198_, 0)) then
												loc_1199_, loc_1205_ = loc_1205_, loc_1199_;
												rt_store_i32(loc_1193_, loc_1199_, 24, loc_1205_)
												loc_1205_ = buffer_read_i32(loc_1193_[1], loc_1206_, 16);
												if not (rt_equal_i32(loc_1205_, 0)) then
													rt_store_i32(loc_1193_, loc_1199_, 16, loc_1205_)
													rt_store_i32(loc_1193_, loc_1205_, 24, loc_1199_)
												end
												loc_1205_ = buffer_read_i32(loc_1193_[1], loc_1206_, 20);
												if not (rt_equal_i32(loc_1205_, 0)) then
													rt_store_i32(loc_1193_, loc_1199_, 20, loc_1205_)
													rt_store_i32(loc_1193_, loc_1205_, 24, loc_1199_)
												end
											end
										end
										if rt_greater_than_u32(loc_1196_, 15) then
											loc_1205_ = bit32_or(loc_1206_ + loc_1200_, 0);
											rt_store_i32(loc_1193_, loc_1205_, 4, rt_or_i32(loc_1196_, 1))
											rt_store_i32(loc_1193_, loc_1206_, 4, rt_or_i32(loc_1200_, 3))
											rt_store_i32(loc_1193_, bit32_or(loc_1205_ + loc_1196_, 0), 0, loc_1196_)
											if rt_greater_than_u32(loc_1196_, 255) then
												loc_1198_ = 31;
												if not (rt_greater_than_u32(loc_1196_, 16777215)) then
													loc_1199_ = loc_1196_;
													loc_1200_ = loc_1198_;
													loc_1196_ = loc_1199_;
													loc_1200_ = rt_leading_zeroes_i32(rt_shift_right_u32(loc_1199_, 8));
													loc_1198_ = bit32_or(bit32_or(rt_and_i32(rt_shift_right_u32(loc_1199_, bit32_or(38 - loc_1200_, 0)), 1) - rt_shift_left_i32(loc_1200_, 1), 0) + 62, 0);
												end
												rt_store_i32(loc_1193_, loc_1205_, 28, loc_1198_)
												rt_store_i64(loc_1193_, loc_1205_, 16, into_bits_i64(0, 0))
												loc_1199_ = rt_shift_left_i32(1, loc_1198_);
												loc_1200_ = bit32_or(rt_shift_left_i32(loc_1198_, 2) + 72268, 0);
												if rt_not_equal_i32(rt_and_i32(loc_1197_, loc_1199_), 0) then
													loc_1197_ = 0;
													loc_1199_ = bit32_or(25 - rt_shift_right_u32(loc_1198_, 1), 0);
													if rt_equal_i32(loc_1198_, 31) then
														loc_1198_ = loc_1196_;
													else
														loc_1198_ = loc_1196_;
														loc_1197_ = loc_1199_;
													end
													loc_1199_ = buffer_read_i32(loc_1193_[1], loc_1200_, 0);
													loc_1197_ = rt_shift_left_i32(loc_1196_, loc_1197_);
													repeat
														rt_yield_budget = rt_yield_budget - 1
														if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
														loc_1203_ = buffer_read_i32(loc_1193_[1], loc_1199_, 4);
														if rt_equal_i32(rt_and_i32(loc_1203_, -8), loc_1198_) then
															loc_1200_ = loc_1199_;
															loc_1196_ = 0;
															loc_1202_ = 1;
														else
															loc_1200_ = loc_1199_;
															loc_1203_ = loc_1207_;
															loc_1207_ = loc_1199_;
															loc_1207_ = bit32_or(loc_1200_ + rt_and_i32(rt_shift_right_u32(loc_1197_, 29), 4), 0);
															loc_1199_ = buffer_read_i32(loc_1193_[1], loc_1207_, 16);
															loc_1197_ = rt_shift_left_i32(loc_1197_, 1);
															if rt_not_equal_i32(loc_1199_, 0) then
																loc_1196_ = 1;
																loc_1202_ = 65535;
															else
																loc_1196_ = 0;
																loc_1202_ = 0;
															end
														end
														loc_1203_ = loc_1196_;
													until loc_1196_ == 0
													if rt_not_equal_i32(loc_1202_, 0) then
														loc_1207_ = buffer_read_i32(loc_1193_[1], loc_1200_, 8);
														rt_store_i32(loc_1193_, loc_1207_, 12, loc_1205_)
														rt_store_i32(loc_1193_, loc_1200_, 8, loc_1205_)
														rt_store_i32(loc_1193_, loc_1205_, 24, 0)
														rt_store_i32(loc_1193_, loc_1205_, 12, loc_1200_)
														rt_store_i32(loc_1193_, loc_1205_, 8, loc_1207_)
													else
														rt_store_i32(loc_1193_, bit32_or(loc_1207_ + 16, 0), 0, loc_1205_)
														rt_store_i32(loc_1193_, loc_1205_, 24, loc_1200_)
														rt_store_i32(loc_1193_, loc_1205_, 12, loc_1205_)
														rt_store_i32(loc_1193_, loc_1205_, 8, loc_1205_)
													end
												else
													loc_1196_, loc_1207_ = loc_1207_, loc_1196_;
													rt_store_i32(loc_1193_, loc_1200_, 0, loc_1205_)
													rt_store_i32(loc_1193_, 0, 71968, rt_or_i32(loc_1197_, loc_1199_))
													rt_store_i32(loc_1193_, loc_1205_, 24, loc_1200_)
													rt_store_i32(loc_1193_, loc_1205_, 8, loc_1205_)
													rt_store_i32(loc_1193_, loc_1205_, 12, loc_1205_)
												end
											else
												loc_1200_ = loc_1197_;
												loc_1205_, loc_1207_ = loc_1207_, loc_1205_;
												loc_1200_ = buffer_read_i32(loc_1193_[1], 0, 71964);
												loc_1205_ = rt_shift_left_i32(1, rt_shift_right_u32(loc_1196_, 3));
												loc_1199_ = bit32_or(rt_and_i32(loc_1196_, -8) + 72004, 0);
												if rt_not_equal_i32(rt_and_i32(loc_1200_, loc_1205_), 0) then
													loc_1205_ = buffer_read_i32(loc_1193_[1], loc_1199_, 8);
												else
													rt_store_i32(loc_1193_, 0, 71964, rt_or_i32(loc_1200_, loc_1205_))
													loc_1205_ = loc_1199_;
												end
												rt_store_i32(loc_1193_, loc_1205_, 12, loc_1207_)
												rt_store_i32(loc_1193_, loc_1199_, 8, loc_1207_)
												rt_store_i32(loc_1193_, loc_1207_, 12, loc_1199_)
												rt_store_i32(loc_1193_, loc_1207_, 8, loc_1205_)
											end
										else
											loc_1205_ = loc_1197_;
											loc_1207_ = rt_or_i32(loc_1196_, loc_1200_);
											rt_store_i32(loc_1193_, loc_1206_, 4, rt_or_i32(loc_1207_, 3))
											loc_1205_ = bit32_or(loc_1206_ + loc_1207_, 0);
											loc_1207_ = buffer_read_i32(loc_1193_[1], loc_1205_, 4);
											rt_store_i32(loc_1193_, loc_1205_, 4, rt_or_i32(loc_1207_, 1))
										end
										loc_1207_ = 1;
										loc_1191_ = bit32_or(loc_1206_ + 8, 0);
									end
								end
							end
						end
					end
				else
					loc_1205_ = loc_1202_;
					loc_1202_ = loc_1197_;
					loc_1206_ = loc_1201_;
					loc_1201_ = loc_1199_;
					loc_1207_ = loc_1191_;
					loc_1208_ = loc_1203_;
					loc_1203_ = loc_1196_;
					loc_1209_ = loc_1200_;
					loc_1200_ = loc_1204_;
					loc_1204_ = loc_1198_;
					loc_1209_ = buffer_read_i32(loc_1193_[1], 0, 71964);
					loc_1205_ = 16;
					loc_1206_ = rt_and_i32(bit32_or(loc_1207_ + 19, 0), 496);
					if rt_less_than_u32(loc_1207_, 11) then
						loc_1199_ = loc_1200_;
						loc_1200_ = loc_1205_;
						loc_1205_ = loc_1208_;
						loc_1207_ = loc_1209_;
						loc_1208_ = loc_1206_;
					else
						loc_1199_ = loc_1200_;
						loc_1207_ = loc_1209_;
						loc_1205_, loc_1208_ = loc_1208_, loc_1205_;
						loc_1208_, loc_1206_ = loc_1206_, loc_1208_;
						loc_1200_ = loc_1208_;
					end
					loc_1208_ = rt_shift_right_u32(loc_1200_, 3);
					loc_1191_ = rt_shift_right_u32(loc_1209_, loc_1208_);
					if rt_equal_i32(rt_and_i32(loc_1191_, 3), 0) then
						loc_1206_ = buffer_read_i32(loc_1193_[1], 0, 71972);
						if rt_less_than_equal_u32(loc_1200_, loc_1206_) then
							loc_1207_ = 0;
						else
							if rt_equal_i32(loc_1191_, 0) then
								loc_1209_ = loc_1208_;
								loc_1208_ = loc_1207_;
								loc_1207_ = loc_1206_;
								loc_1206_ = loc_1205_;
								loc_1205_ = buffer_read_i32(loc_1193_[1], 0, 71968);
								if rt_equal_i32(loc_1205_, 0) then
									loc_1207_ = 0;
								else
									loc_1198_ = loc_1206_;
									loc_1206_ = loc_1199_;
									loc_1199_ = loc_1207_;
									loc_1209_ = loc_1201_;
									loc_1201_ = loc_1205_;
									loc_1205_ = loc_1208_;
									loc_1208_ = loc_1191_;
									loc_1208_ = buffer_read_i32(loc_1193_[1], rt_shift_left_i32(rt_trailing_zeroes_i32(loc_1201_), 2), 72268);
									loc_1207_ = buffer_read_i32(loc_1193_[1], loc_1208_, 4);
									loc_1209_ = loc_1208_;
									loc_1207_ = bit32_or(rt_and_i32(loc_1207_, -8) - loc_1200_, 0);
									loc_1196_ = loc_1198_;
									loc_1198_ = loc_1201_;
									loc_1191_ = loc_1206_;
									repeat
										rt_yield_budget = rt_yield_budget - 1
										if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
										loc_1206_ = buffer_read_i32(loc_1193_[1], loc_1209_, 16);
										if rt_not_equal_i32(loc_1206_, 0) then
											loc_1203_, loc_1206_ = loc_1206_, loc_1203_;
											loc_1201_ = 0;
										else
											loc_1203_, loc_1206_ = loc_1206_, loc_1203_;
											loc_1203_ = buffer_read_i32(loc_1193_[1], loc_1209_, 20);
											if rt_equal_i32(loc_1203_, 0) then
												loc_1201_ = 1;
												loc_1206_ = 0;
											else
												loc_1201_ = 0;
											end
										end
										if not (rt_not_equal_i32(loc_1201_, 0)) then
											loc_1202_, loc_1209_ = loc_1209_, loc_1202_;
											loc_1209_, loc_1206_ = loc_1206_, loc_1209_;
											loc_1206_, loc_1207_ = loc_1207_, loc_1206_;
											loc_1209_ = buffer_read_i32(loc_1193_[1], loc_1203_, 4);
											loc_1207_ = bit32_or(rt_and_i32(loc_1209_, -8) - loc_1200_, 0);
											loc_1209_ = (rt_less_than_u32(loc_1207_, loc_1206_) and 1 or 0);
											if rt_not_equal_i32(loc_1209_, 0) then
												loc_1203_, loc_1206_ = loc_1206_, loc_1203_;
												loc_1206_, loc_1208_ = loc_1208_, loc_1206_;
											else
												loc_1203_, loc_1206_ = loc_1206_, loc_1203_;
												loc_1206_, loc_1208_ = loc_1208_, loc_1206_;
												loc_1207_ = loc_1203_;
											end
											if rt_not_equal_i32(loc_1209_, 0) then
												loc_1209_ = loc_1208_;
											else
												loc_1209_ = loc_1208_;
												loc_1208_ = loc_1206_;
											end
											loc_1206_ = 1;
											loc_1202_ = 65535;
										end
										loc_1203_ = loc_1206_;
									until loc_1206_ == 0
									loc_1201_ = buffer_read_i32(loc_1193_[1], loc_1208_, 24);
									loc_1209_ = buffer_read_i32(loc_1193_[1], loc_1208_, 12);
									if rt_equal_i32(loc_1209_, loc_1208_) then
										loc_1206_ = buffer_read_i32(loc_1193_[1], loc_1208_, 20);
										if rt_equal_i32(loc_1206_, 0) then
											loc_1197_ = buffer_read_i32(loc_1193_[1], loc_1208_, 16);
											if rt_equal_i32(loc_1197_, 0) then
												loc_1209_ = 1;
												loc_1206_ = 0;
											else
												loc_1196_, loc_1208_ = loc_1208_, loc_1196_;
												loc_1208_, loc_1209_ = loc_1209_, loc_1208_;
												loc_1209_ = 0;
												loc_1206_ = loc_1208_;
												loc_1208_ = loc_1196_;
												loc_1196_ = bit32_or(loc_1196_ + 16, 0);
											end
										else
											loc_1196_, loc_1208_ = loc_1208_, loc_1196_;
											loc_1208_, loc_1209_ = loc_1209_, loc_1208_;
											loc_1209_ = 0;
											loc_1197_ = loc_1206_;
											loc_1206_ = loc_1208_;
											loc_1208_ = loc_1196_;
											loc_1196_ = bit32_or(loc_1196_ + 20, 0);
										end
										if not (rt_not_equal_i32(loc_1209_, 0)) then
											loc_1209_ = loc_1191_;
											loc_1196_, loc_1197_ = loc_1197_, loc_1196_;
											loc_1191_ = loc_1197_;
											loc_1197_ = loc_1209_;
											repeat
												rt_yield_budget = rt_yield_budget - 1
												if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
												loc_1209_ = loc_1191_;
												loc_1196_, loc_1197_ = loc_1197_, loc_1196_;
												loc_1197_, loc_1206_ = loc_1206_, loc_1197_;
												loc_1196_ = buffer_read_i32(loc_1193_[1], loc_1206_, 20);
												loc_1191_ = bit32_or(loc_1206_ + 20, 0);
												if rt_not_equal_i32(loc_1196_, 0) then
													loc_1197_ = loc_1209_;
													loc_1209_ = loc_1202_;
													loc_1209_ = 1;
													loc_1202_ = 65535;
												else
													loc_1197_ = loc_1209_;
													loc_1203_ = loc_1196_;
													loc_1209_ = loc_1202_;
													loc_1202_ = loc_1191_;
													loc_1196_ = buffer_read_i32(loc_1193_[1], loc_1206_, 16);
													loc_1191_ = bit32_or(loc_1206_ + 16, 0);
													if rt_not_equal_i32(loc_1196_, 0) then
														loc_1209_ = 1;
														loc_1202_ = 65535;
													else
														loc_1203_ = loc_1209_;
														loc_1209_ = 0;
														loc_1202_ = loc_1203_;
													end
												end
												loc_1203_ = loc_1209_;
											until loc_1209_ == 0
											rt_store_i32(loc_1193_, loc_1197_, 0, 0)
										end
									else
										loc_1197_ = loc_1191_;
										loc_1206_ = loc_1196_;
										loc_1206_ = buffer_read_i32(loc_1193_[1], loc_1208_, 8);
										rt_store_i32(loc_1193_, loc_1206_, 12, loc_1209_)
										rt_store_i32(loc_1193_, loc_1209_, 8, loc_1206_)
										loc_1206_ = loc_1209_;
									end
									if not (rt_equal_i32(loc_1201_, 0)) then
										loc_1191_ = loc_1198_;
										loc_1197_ = buffer_read_i32(loc_1193_[1], loc_1208_, 28);
										loc_1198_ = rt_shift_left_i32(loc_1197_, 2);
										loc_1196_ = buffer_read_i32(loc_1193_[1], loc_1198_, 72268);
										if rt_not_equal_i32(loc_1208_, loc_1196_) then
											loc_1196_ = loc_1191_;
											loc_1198_ = buffer_read_i32(loc_1193_[1], loc_1201_, 16);
											if rt_not_equal_i32(loc_1198_, loc_1208_) then
												rt_store_i32(loc_1193_, loc_1201_, 20, loc_1206_)
											else
												rt_store_i32(loc_1193_, loc_1201_, 16, loc_1206_)
											end
											if rt_equal_i32(loc_1206_, 0) then
												loc_1198_ = 1;
											else
												loc_1198_ = 0;
											end
										else
											loc_1196_ = loc_1191_;
											rt_store_i32(loc_1193_, bit32_or(loc_1198_ + 72268, 0), 0, loc_1206_)
											if rt_not_equal_i32(loc_1206_, 0) then
												loc_1198_ = loc_1197_;
												loc_1197_ = loc_1196_;
												loc_1198_ = 0;
											else
												loc_1198_ = loc_1197_;
												loc_1197_ = loc_1196_;
												rt_store_i32(loc_1193_, 0, 71968, rt_and_i32(loc_1197_, rt_rotate_left_i32(-2, loc_1198_)))
												loc_1198_ = 1;
											end
										end
										if not (rt_not_equal_i32(loc_1198_, 0)) then
											loc_1198_ = loc_1206_;
											rt_store_i32(loc_1193_, loc_1198_, 24, loc_1201_)
											loc_1206_ = buffer_read_i32(loc_1193_[1], loc_1208_, 16);
											if not (rt_equal_i32(loc_1206_, 0)) then
												rt_store_i32(loc_1193_, loc_1198_, 16, loc_1206_)
												rt_store_i32(loc_1193_, loc_1206_, 24, loc_1198_)
											end
											loc_1206_ = buffer_read_i32(loc_1193_[1], loc_1208_, 20);
											if not (rt_equal_i32(loc_1206_, 0)) then
												rt_store_i32(loc_1193_, loc_1198_, 20, loc_1206_)
												rt_store_i32(loc_1193_, loc_1206_, 24, loc_1198_)
											end
										end
									end
									if rt_greater_than_u32(loc_1207_, 15) then
										loc_1206_ = bit32_or(loc_1208_ + loc_1200_, 0);
										rt_store_i32(loc_1193_, loc_1206_, 4, rt_or_i32(loc_1207_, 1))
										rt_store_i32(loc_1193_, loc_1208_, 4, rt_or_i32(loc_1200_, 3))
										rt_store_i32(loc_1193_, bit32_or(loc_1206_ + loc_1207_, 0), 0, loc_1207_)
										if not (rt_equal_i32(loc_1199_, 0)) then
											loc_1198_ = loc_1199_;
											loc_1199_ = buffer_read_i32(loc_1193_[1], 0, 71984);
											loc_1200_ = bit32_or(rt_and_i32(loc_1198_, -8) + 72004, 0);
											loc_1198_ = rt_shift_left_i32(1, rt_shift_right_u32(loc_1198_, 3));
											if rt_not_equal_i32(rt_and_i32(loc_1198_, loc_1205_), 0) then
												loc_1205_ = buffer_read_i32(loc_1193_[1], loc_1200_, 8);
											else
												loc_1200_, loc_1205_ = loc_1205_, loc_1200_;
												rt_store_i32(loc_1193_, 0, 71964, rt_or_i32(loc_1198_, loc_1200_))
												loc_1200_ = loc_1205_;
											end
											rt_store_i32(loc_1193_, loc_1205_, 12, loc_1199_)
											rt_store_i32(loc_1193_, loc_1200_, 8, loc_1199_)
											rt_store_i32(loc_1193_, loc_1199_, 12, loc_1200_)
											rt_store_i32(loc_1193_, loc_1199_, 8, loc_1205_)
										end
										rt_store_i32(loc_1193_, 0, 71984, loc_1206_)
										rt_store_i32(loc_1193_, 0, 71972, loc_1207_)
									else
										loc_1206_ = loc_1205_;
										loc_1205_ = loc_1199_;
										loc_1207_ = rt_or_i32(loc_1207_, loc_1200_);
										rt_store_i32(loc_1193_, loc_1208_, 4, rt_or_i32(loc_1207_, 3))
										loc_1206_ = bit32_or(loc_1208_ + loc_1207_, 0);
										loc_1207_ = buffer_read_i32(loc_1193_[1], loc_1206_, 4);
										rt_store_i32(loc_1193_, loc_1206_, 4, rt_or_i32(loc_1207_, 1))
									end
									loc_1207_ = 1;
									loc_1191_ = bit32_or(loc_1208_ + 8, 0);
								end
							else
								loc_1209_ = loc_1208_;
								loc_1208_ = loc_1205_;
								loc_1205_ = loc_1207_;
								loc_1207_ = loc_1206_;
								loc_1206_ = loc_1199_;
								loc_1208_ = rt_shift_left_i32(2, loc_1209_);
								loc_1208_ = rt_trailing_zeroes_i32(rt_and_i32(rt_shift_left_i32(loc_1191_, loc_1209_), rt_or_i32(loc_1208_, bit32_or(0 - loc_1208_, 0))));
								loc_1199_ = rt_shift_left_i32(loc_1208_, 3);
								loc_1209_ = buffer_read_i32(loc_1193_[1], loc_1199_, 72012);
								loc_1206_ = buffer_read_i32(loc_1193_[1], loc_1209_, 8);
								loc_1199_ = bit32_or(loc_1199_ + 72004, 0);
								if rt_not_equal_i32(loc_1199_, loc_1206_) then
									loc_1205_, loc_1207_ = loc_1207_, loc_1205_;
									loc_1207_, loc_1206_ = loc_1206_, loc_1207_;
									rt_store_i32(loc_1193_, loc_1199_, 8, loc_1207_)
									rt_store_i32(loc_1193_, loc_1207_, 12, loc_1199_)
								else
									loc_1199_, loc_1206_ = loc_1206_, loc_1199_;
									loc_1206_, loc_1205_ = loc_1205_, loc_1206_;
									loc_1205_, loc_1207_ = loc_1207_, loc_1205_;
									loc_1206_ = rt_and_i32(loc_1206_, rt_rotate_left_i32(-2, loc_1208_));
									rt_store_i32(loc_1193_, 0, 71964, loc_1206_)
								end
								rt_store_i32(loc_1193_, loc_1209_, 4, rt_or_i32(loc_1200_, 3))
								loc_1207_ = rt_shift_left_i32(loc_1208_, 3);
								loc_1208_ = bit32_or(loc_1207_ - loc_1200_, 0);
								rt_store_i32(loc_1193_, bit32_or(loc_1209_ + loc_1207_, 0), 0, loc_1208_)
								loc_1207_ = bit32_or(loc_1209_ + loc_1200_, 0);
								rt_store_i32(loc_1193_, loc_1207_, 4, rt_or_i32(loc_1208_, 1))
								if not (rt_equal_i32(loc_1205_, 0)) then
									loc_1199_ = loc_1205_;
									loc_1205_ = loc_1200_;
									loc_1205_ = buffer_read_i32(loc_1193_[1], 0, 71984);
									loc_1200_ = bit32_or(rt_and_i32(loc_1199_, -8) + 72004, 0);
									loc_1199_ = rt_shift_left_i32(1, rt_shift_right_u32(loc_1199_, 3));
									if rt_not_equal_i32(rt_and_i32(loc_1206_, loc_1199_), 0) then
										loc_1206_ = buffer_read_i32(loc_1193_[1], loc_1200_, 8);
									else
										loc_1200_, loc_1206_ = loc_1206_, loc_1200_;
										rt_store_i32(loc_1193_, 0, 71964, rt_or_i32(loc_1200_, loc_1199_))
										loc_1200_ = loc_1206_;
									end
									rt_store_i32(loc_1193_, loc_1206_, 12, loc_1205_)
									rt_store_i32(loc_1193_, loc_1200_, 8, loc_1205_)
									rt_store_i32(loc_1193_, loc_1205_, 12, loc_1200_)
									rt_store_i32(loc_1193_, loc_1205_, 8, loc_1206_)
								end
								rt_store_i32(loc_1193_, 0, 71984, loc_1207_)
								rt_store_i32(loc_1193_, 0, 71972, loc_1208_)
								loc_1207_ = 1;
								loc_1191_ = bit32_or(loc_1209_ + 8, 0);
							end
						end
					else
						loc_1206_ = loc_1199_;
						loc_1209_ = loc_1200_;
						loc_1205_, loc_1207_ = loc_1207_, loc_1205_;
						loc_1208_ = rt_exclusive_or_i32(rt_or_i32(rt_and_i32(loc_1191_, 1), loc_1208_), 1);
						loc_1207_ = rt_shift_left_i32(loc_1208_, 3);
						loc_1209_ = buffer_read_i32(loc_1193_[1], loc_1207_, 72012);
						loc_1206_ = buffer_read_i32(loc_1193_[1], loc_1209_, 8);
						loc_1207_ = bit32_or(loc_1207_ + 72004, 0);
						if rt_not_equal_i32(loc_1207_, loc_1206_) then
							rt_store_i32(loc_1193_, loc_1207_, 8, loc_1206_)
							rt_store_i32(loc_1193_, loc_1206_, 12, loc_1207_)
						else
							loc_1206_, loc_1207_ = loc_1207_, loc_1206_;
							rt_store_i32(loc_1193_, 0, 71964, rt_and_i32(loc_1205_, rt_rotate_left_i32(-2, loc_1208_)))
						end
						loc_1200_ = rt_shift_left_i32(loc_1208_, 3);
						rt_store_i32(loc_1193_, loc_1209_, 4, rt_or_i32(loc_1200_, 3))
						loc_1207_ = bit32_or(loc_1209_ + loc_1200_, 0);
						loc_1208_ = buffer_read_i32(loc_1193_[1], loc_1207_, 4);
						rt_store_i32(loc_1193_, loc_1207_, 4, rt_or_i32(loc_1208_, 1))
						loc_1207_ = 1;
						loc_1191_ = bit32_or(loc_1209_ + 8, 0);
					end
				end
				if not (rt_not_equal_i32(loc_1207_, 0)) then
					loc_1207_ = loc_1191_;
					loc_1207_ = buffer_read_i32(loc_1193_[1], 0, 71972);
					if rt_less_than_u32(loc_1207_, loc_1200_) then
						loc_1199_ = loc_1200_;
						loc_1200_ = loc_1201_;
						loc_1201_ = buffer_read_i32(loc_1193_[1], 0, 71976);
						if rt_less_than_equal_u32(loc_1201_, loc_1199_) then
							loc_1207_ = buffer_read_i32(loc_1193_[1], 0, 72436);
							if rt_equal_i32(loc_1207_, 0) then
								rt_store_i64(loc_1193_, 0, 72448, into_bits_i64(4294967295, 4294967295))
								rt_store_i64(loc_1193_, 0, 72440, into_bits_i64(65536, 65536))
								rt_store_i32(loc_1193_, 0, 72436, rt_exclusive_or_i32(rt_and_i32(bit32_or(loc_1204_ + 12, 0), -16), 1431655768))
								rt_store_i32(loc_1193_, 0, 72456, 0)
								rt_store_i32(loc_1193_, 0, 72408, 0)
								loc_1206_ = 65536;
							else
								loc_1206_ = buffer_read_i32(loc_1193_[1], 0, 72444);
							end
							loc_1207_ = 0;
							loc_1198_ = bit32_or(0 - loc_1206_, 0);
							loc_1205_ = bit32_or(loc_1199_ + 71, 0);
							loc_1197_ = bit32_or(loc_1206_ + loc_1205_, 0);
							loc_1196_ = rt_and_i32(loc_1197_, loc_1198_);
							if rt_greater_than_u32(loc_1196_, loc_1199_) then
								loc_1191_ = buffer_read_i32(loc_1193_[1], 0, 72404);
								if rt_equal_i32(loc_1191_, 0) then
									loc_1207_ = 0;
								else
									loc_1206_ = buffer_read_i32(loc_1193_[1], 0, 72396);
									loc_1207_ = bit32_or(loc_1206_ + loc_1196_, 0);
									if rt_less_than_equal_u32(loc_1207_, loc_1206_) then
										loc_1207_ = 0;
									else
										if rt_less_than_equal_u32(loc_1207_, loc_1191_) then
											loc_1207_ = 1;
										else
											loc_1207_ = 0;
										end
									end
									if rt_not_equal_i32(loc_1207_, 0) then
										loc_1207_ = 0;
									else
										loc_1207_ = loc_1191_;
										rt_store_i32(loc_1193_, 0, 70852, 48)
										loc_1207_ = 1;
										loc_1191_ = 0;
									end
								end
								if not (rt_not_equal_i32(loc_1207_, 0)) then
									loc_1207_ = rt_load_i32_from_u8(loc_1193_, 0, 72408);
									if rt_not_equal_i32(rt_and_i32(loc_1207_, 4), 0) then
										loc_1206_ = loc_1200_;
										loc_1200_ = loc_1198_;
										loc_1198_ = loc_1196_;
										loc_1197_, loc_1205_ = loc_1205_, loc_1197_;
										loc_1205_, loc_1203_ = loc_1203_, loc_1205_;
										loc_1203_, loc_1202_ = loc_1202_, loc_1203_;
										loc_1202_, loc_1201_ = loc_1201_, loc_1202_;
										loc_1201_, loc_1199_ = loc_1199_, loc_1201_;
										loc_1206_ = 0;
									else
										loc_1206_ = loc_1200_;
										loc_1200_ = loc_1198_;
										loc_1198_ = loc_1196_;
										loc_1197_, loc_1205_ = loc_1205_, loc_1197_;
										loc_1205_, loc_1203_ = loc_1203_, loc_1205_;
										loc_1203_, loc_1202_ = loc_1202_, loc_1203_;
										loc_1202_, loc_1201_ = loc_1201_, loc_1202_;
										loc_1201_, loc_1199_ = loc_1199_, loc_1201_;
										if rt_equal_i32(loc_1206_, 0) then
											loc_1197_, loc_1206_ = loc_1206_, loc_1197_;
											loc_1197_ = 0;
										else
											loc_1207_ = loc_1191_;
											loc_1197_, loc_1206_ = loc_1206_, loc_1197_;
											loc_1191_ = 72412;
											repeat
												rt_yield_budget = rt_yield_budget - 1
												if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
												loc_1207_ = buffer_read_i32(loc_1193_[1], loc_1191_, 0);
												if rt_less_than_u32(loc_1197_, loc_1207_) then
													loc_1196_ = loc_1205_;
													loc_1205_ = loc_1207_;
													loc_1205_ = 0;
												else
													loc_1196_ = loc_1205_;
													loc_1205_ = loc_1207_;
													loc_1207_ = buffer_read_i32(loc_1193_[1], loc_1191_, 4);
													if rt_less_than_u32(loc_1197_, bit32_or(loc_1205_ + loc_1207_, 0)) then
														loc_1205_ = loc_1196_;
														loc_1205_ = 1;
														loc_1196_ = 0;
														loc_1203_ = 0;
													else
														loc_1205_ = 0;
													end
												end
												if not (rt_not_equal_i32(loc_1205_, 0)) then
													loc_1205_ = loc_1196_;
													loc_1191_ = buffer_read_i32(loc_1193_[1], loc_1191_, 8);
													if rt_not_equal_i32(loc_1191_, 0) then
														loc_1196_ = 1;
														loc_1203_ = 65535;
													else
														loc_1196_ = 0;
														loc_1203_ = 1;
													end
												end
												loc_1205_ = loc_1196_;
											until loc_1196_ == 0
											if rt_not_equal_i32(loc_1203_, 0) then
												loc_1197_ = 0;
											else
												loc_1200_ = rt_and_i32(bit32_or(loc_1199_ - loc_1202_, 0), loc_1200_);
												if rt_greater_than_u32(loc_1200_, 2147483646) then
													loc_1197_ = 2;
												else
													loc_1199_ = loc_1190_;
													loc_1199_ = loc_1194_[1](loc_1200_, loc_1199_)
													loc_1196_ = buffer_read_i32(loc_1193_[1], loc_1191_, 0);
													loc_1197_ = buffer_read_i32(loc_1193_[1], loc_1191_, 4);
													if rt_equal_i32(loc_1199_, bit32_or(loc_1196_ + loc_1197_, 0)) then
														if rt_not_equal_i32(loc_1199_, -1) then
															loc_1197_ = 3;
														else
															loc_1197_ = 2;
														end
													else
														loc_1197_ = loc_1191_;
														loc_1197_ = 1;
														loc_1191_ = loc_1199_;
													end
												end
											end
										end
										if (loc_1197_) >= 0 and (loc_1197_) < 3 then
											if (loc_1197_) < 1 then
												loc_1199_ = loc_1190_;
												loc_1199_ = loc_1194_[1](0, loc_1199_)
												if rt_equal_i32(loc_1199_, -1) then
													loc_1197_ = 1;
												else
													loc_1197_ = loc_1200_;
													loc_1200_ = loc_1191_;
													loc_1191_ = buffer_read_i32(loc_1193_[1], 0, 72440);
													loc_1197_ = bit32_or(loc_1191_ + -1, 0);
													if rt_equal_i32(rt_and_i32(loc_1197_, loc_1199_), 0) then
														loc_1200_ = loc_1198_;
													else
														loc_1196_ = loc_1198_;
														loc_1200_ = loc_1191_;
														loc_1191_ = loc_1200_;
														loc_1200_ = bit32_or(bit32_or(loc_1198_ - loc_1199_, 0) + rt_and_i32(bit32_or(loc_1197_ + loc_1199_, 0), bit32_or(0 - loc_1200_, 0)), 0);
													end
													if rt_less_than_equal_u32(loc_1200_, loc_1201_) then
														loc_1197_ = 1;
													else
														if rt_greater_than_u32(loc_1200_, 2147483646) then
															loc_1197_ = 1;
														else
															loc_1197_ = loc_1191_;
															loc_1191_ = buffer_read_i32(loc_1193_[1], 0, 72404);
															if rt_equal_i32(loc_1191_, 0) then
																loc_1197_ = 0;
															else
																loc_1197_ = buffer_read_i32(loc_1193_[1], 0, 72396);
																loc_1202_ = bit32_or(loc_1197_ + loc_1200_, 0);
																if rt_less_than_equal_u32(loc_1202_, loc_1197_) then
																	loc_1197_ = 1;
																else
																	if rt_greater_than_u32(loc_1202_, loc_1191_) then
																		loc_1197_ = 2;
																	else
																		loc_1197_ = 0;
																	end
																end
															end
															if (loc_1197_) >= 0 and (loc_1197_) < 2 then
																if (loc_1197_) < 1 then
																	loc_1197_ = loc_1191_;
																	loc_1197_ = loc_1190_;
																	loc_1191_ = loc_1194_[1](loc_1200_, loc_1197_)
																	if rt_not_equal_i32(loc_1191_, loc_1199_) then
																		loc_1197_ = 0;
																	else
																		loc_1197_ = 2;
																	end
																else
																	loc_1197_ = 1;
																end
															else
																loc_1197_ = 1;
															end
														end
													end
												end
											elseif (loc_1197_) > 1 then
												loc_1197_ = 1;
											else
												loc_1197_ = 0;
											end
										else
											loc_1197_ = 3;
										end
										if (loc_1197_) >= 0 and (loc_1197_) < 3 then
											if (loc_1197_) < 1 then
												if rt_greater_than_equal_u32(loc_1200_, bit32_or(loc_1201_ + 72, 0)) then
													loc_1206_ = 0;
												else
													if rt_equal_i32(loc_1191_, -1) then
														loc_1206_ = 0;
													else
														loc_1197_ = buffer_read_i32(loc_1193_[1], 0, 72444);
														loc_1196_ = rt_and_i32(bit32_or(bit32_or(loc_1206_ - loc_1200_, 0) + loc_1197_, 0), bit32_or(0 - loc_1197_, 0));
														if rt_less_than_equal_u32(loc_1196_, 2147483646) then
															loc_1197_ = loc_1194_;
															loc_1206_ = loc_1190_;
															loc_1194_ = loc_1197_[1](loc_1196_, loc_1206_)
															if rt_equal_i32(loc_1194_, -1) then
																loc_1194_ = loc_1197_;
																loc_1206_ = loc_1197_[1](bit32_or(0 - loc_1200_, 0), loc_1206_)
																loc_1206_ = 1;
															else
																loc_1194_ = loc_1199_;
																loc_1199_ = loc_1191_;
																loc_1197_, loc_1206_ = loc_1206_, loc_1197_;
																loc_1194_ = loc_1206_;
																loc_1206_ = 2;
																loc_1191_ = loc_1199_;
																loc_1200_ = bit32_or(loc_1196_ + loc_1200_, 0);
																loc_1190_ = loc_1197_;
															end
														else
															loc_1197_ = loc_1190_;
															loc_1206_ = loc_1194_;
															loc_1194_ = loc_1199_;
															loc_1199_ = loc_1191_;
															loc_1194_ = loc_1206_;
															loc_1206_ = 3;
															loc_1191_ = loc_1199_;
															loc_1190_ = loc_1197_;
														end
													end
												end
												if (loc_1206_) >= 0 and (loc_1206_) < 3 then
													if (loc_1206_) < 1 then
														loc_1206_ = loc_1199_;
														if rt_not_equal_i32(loc_1191_, -1) then
															loc_1199_ = loc_1191_;
															loc_1206_ = 4;
														else
															loc_1199_ = loc_1191_;
															loc_1206_ = 0;
														end
													elseif (loc_1206_) > 1 then
														loc_1206_ = 3;
													else
														loc_1206_ = 0;
													end
												else
													loc_1206_ = 2;
												end
											elseif (loc_1197_) > 1 then
												loc_1206_ = 1;
											else
												loc_1206_ = 0;
											end
										else
											loc_1206_ = 5;
										end
										if (loc_1206_) >= 0 and (loc_1206_) < 5 then
											if (loc_1206_) < 2 then
												if (loc_1206_) < 1 then
													loc_1206_ = buffer_read_i32(loc_1193_[1], 0, 72408);
													rt_store_i32(loc_1193_, 0, 72408, rt_or_i32(loc_1206_, 4))
													loc_1206_ = 0;
												else
													loc_1206_ = 1;
												end
											elseif (loc_1206_) > 2 then
												if (loc_1206_) < 4 then
													loc_1206_ = 1;
												else
													loc_1206_ = 1;
												end
											else
												loc_1206_ = 1;
											end
										else
											loc_1206_ = 1;
										end
									end
									if rt_not_equal_i32(loc_1206_, 0) then
										loc_1206_ = 0;
									else
										if rt_greater_than_u32(loc_1198_, 2147483646) then
											loc_1206_ = 1;
										else
											loc_1206_ = loc_1191_;
											loc_1206_ = loc_1190_;
											loc_1199_ = loc_1194_[1](loc_1198_, loc_1206_)
											loc_1191_ = loc_1194_[1](0, loc_1206_)
											if rt_equal_i32(loc_1199_, -1) then
												loc_1206_ = 1;
											else
												if rt_equal_i32(loc_1191_, -1) then
													loc_1206_ = 1;
												else
													if rt_greater_than_equal_u32(loc_1199_, loc_1191_) then
														loc_1206_ = 1;
													else
														loc_1206_ = loc_1200_;
														loc_1200_ = bit32_or(loc_1191_ - loc_1199_, 0);
														if rt_less_than_equal_u32(loc_1200_, bit32_or(loc_1201_ + 56, 0)) then
															loc_1206_ = 1;
														else
															loc_1206_ = 0;
														end
													end
												end
											end
										end
									end
									if rt_not_equal_i32(loc_1206_, 0) then
										loc_1205_ = 0;
									else
										loc_1206_ = loc_1191_;
										loc_1206_ = buffer_read_i32(loc_1193_[1], 0, 72396);
										loc_1206_ = bit32_or(loc_1206_ + loc_1200_, 0);
										rt_store_i32(loc_1193_, 0, 72396, loc_1206_)
										loc_1197_ = buffer_read_i32(loc_1193_[1], 0, 72400);
										if rt_less_than_equal_u32(loc_1206_, loc_1197_) then
											loc_1197_ = loc_1198_;
											loc_1199_, loc_1202_ = loc_1202_, loc_1199_;
											loc_1200_, loc_1203_ = loc_1203_, loc_1200_;
											loc_1201_, loc_1205_ = loc_1205_, loc_1201_;
										else
											loc_1197_ = loc_1198_;
											loc_1199_, loc_1202_ = loc_1202_, loc_1199_;
											loc_1200_, loc_1203_ = loc_1203_, loc_1200_;
											loc_1201_, loc_1205_ = loc_1205_, loc_1201_;
											rt_store_i32(loc_1193_, 0, 72400, loc_1206_)
										end
										loc_1198_ = buffer_read_i32(loc_1193_[1], 0, 71988);
										if rt_equal_i32(loc_1198_, 0) then
											loc_1201_ = buffer_read_i32(loc_1193_[1], 0, 71980);
											if rt_equal_i32(loc_1201_, 0) then
												loc_1201_ = 0;
											else
												if rt_greater_than_equal_u32(loc_1202_, loc_1201_) then
													loc_1201_ = 1;
												else
													loc_1201_ = 0;
												end
											end
											if not (rt_not_equal_i32(loc_1201_, 0)) then
												rt_store_i32(loc_1193_, 0, 71980, loc_1202_)
											end
											rt_store_i32(loc_1193_, 0, 72416, loc_1203_)
											rt_store_i32(loc_1193_, 0, 72412, loc_1202_)
											rt_store_i32(loc_1193_, 0, 71996, -1)
											loc_1201_ = buffer_read_i32(loc_1193_[1], 0, 72436);
											rt_store_i32(loc_1193_, 0, 72000, loc_1201_)
											rt_store_i32(loc_1193_, 0, 72424, 0)
											loc_1201_ = 0;
											repeat
												rt_yield_budget = rt_yield_budget - 1
												if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
												loc_1200_ = bit32_or(loc_1201_ + 72012, 0);
												rt_store_i32(loc_1193_, bit32_or(loc_1201_ + 72024, 0), 0, loc_1200_)
												loc_1199_ = bit32_or(loc_1201_ + 72004, 0);
												rt_store_i32(loc_1193_, loc_1200_, 0, loc_1199_)
												rt_store_i32(loc_1193_, bit32_or(loc_1201_ + 72016, 0), 0, loc_1199_)
												loc_1199_ = bit32_or(loc_1201_ + 72020, 0);
												rt_store_i32(loc_1193_, bit32_or(loc_1201_ + 72032, 0), 0, loc_1199_)
												rt_store_i32(loc_1193_, loc_1199_, 0, loc_1200_)
												loc_1200_ = bit32_or(loc_1201_ + 72028, 0);
												rt_store_i32(loc_1193_, bit32_or(loc_1201_ + 72040, 0), 0, loc_1200_)
												rt_store_i32(loc_1193_, loc_1200_, 0, loc_1199_)
												rt_store_i32(loc_1193_, bit32_or(loc_1201_ + 72036, 0), 0, loc_1200_)
												loc_1200_ = bit32_or(loc_1201_ + 32, 0);
												loc_1201_ = loc_1200_;
											until not (rt_not_equal_i32(loc_1200_, 256))
											loc_1200_ = rt_and_i32(bit32_or(-8 - loc_1202_, 0), 15);
											loc_1201_ = bit32_or(loc_1202_ + loc_1200_, 0);
											loc_1203_ = bit32_or(loc_1203_ + -56, 0);
											loc_1191_ = bit32_or(loc_1203_ - loc_1200_, 0);
											rt_store_i32(loc_1193_, loc_1201_, 4, rt_or_i32(loc_1191_, 1))
											loc_1200_ = buffer_read_i32(loc_1193_[1], 0, 72452);
											rt_store_i32(loc_1193_, 0, 71992, loc_1200_)
											rt_store_i32(loc_1193_, 0, 71976, loc_1191_)
											rt_store_i32(loc_1193_, 0, 71988, loc_1201_)
											rt_store_i32(loc_1193_, bit32_or(loc_1202_ + loc_1203_, 0), 4, 56)
											loc_1203_ = 0;
										else
											loc_1206_ = loc_1199_;
											loc_1199_ = loc_1202_;
											loc_1202_ = loc_1200_;
											loc_1200_ = loc_1203_;
											loc_1203_ = loc_1201_;
											loc_1201_ = loc_1198_;
											loc_1191_ = 72412;
											loc_1198_ = loc_1197_;
											repeat
												rt_yield_budget = rt_yield_budget - 1
												if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
												loc_1202_, loc_1206_ = loc_1206_, loc_1202_;
												loc_1206_, loc_1203_ = loc_1203_, loc_1206_;
												loc_1206_ = buffer_read_i32(loc_1193_[1], loc_1191_, 0);
												loc_1198_ = buffer_read_i32(loc_1193_[1], loc_1191_, 4);
												if rt_equal_i32(loc_1199_, bit32_or(loc_1206_ + loc_1198_, 0)) then
													loc_1197_ = 0;
													loc_1202_ = 1;
												else
													loc_1191_ = buffer_read_i32(loc_1193_[1], loc_1191_, 8);
													if rt_not_equal_i32(loc_1191_, 0) then
														loc_1197_ = 1;
														loc_1202_ = 65535;
													else
														loc_1197_ = 0;
														loc_1202_ = 0;
													end
												end
												loc_1203_ = loc_1197_;
											until loc_1197_ == 0
											if rt_not_equal_i32(loc_1202_, 0) then
												if rt_greater_than_equal_u32(loc_1201_, loc_1199_) then
													loc_1206_ = 0;
												else
													if rt_less_than_u32(loc_1201_, loc_1206_) then
														loc_1206_ = 0;
													else
														loc_1206_ = buffer_read_i32(loc_1193_[1], loc_1191_, 12);
														if rt_not_equal_i32(rt_and_i32(loc_1206_, 8), 0) then
															loc_1206_ = 0;
														else
															loc_1206_ = loc_1199_;
															loc_1206_ = buffer_read_i32(loc_1193_[1], 0, 71976);
															loc_1197_ = rt_and_i32(bit32_or(-8 - loc_1201_, 0), 15);
															loc_1199_ = bit32_or(loc_1201_ + loc_1197_, 0);
															loc_1206_ = bit32_or(loc_1206_ + loc_1200_, 0);
															loc_1197_ = bit32_or(loc_1206_ - loc_1197_, 0);
															rt_store_i32(loc_1193_, loc_1199_, 4, rt_or_i32(loc_1197_, 1))
															rt_store_i32(loc_1193_, loc_1191_, 4, bit32_or(loc_1198_ + loc_1200_, 0))
															loc_1196_ = buffer_read_i32(loc_1193_[1], 0, 72452);
															rt_store_i32(loc_1193_, 0, 71992, loc_1196_)
															rt_store_i32(loc_1193_, 0, 71976, loc_1197_)
															rt_store_i32(loc_1193_, 0, 71988, loc_1199_)
															rt_store_i32(loc_1193_, bit32_or(loc_1201_ + loc_1206_, 0), 4, 56)
															loc_1206_ = 1;
														end
													end
												end
											else
												loc_1206_ = 0;
											end
											if rt_not_equal_i32(loc_1206_, 0) then
												loc_1203_ = 0;
											else
												loc_1206_ = loc_1191_;
												loc_1206_ = buffer_read_i32(loc_1193_[1], 0, 71980);
												if rt_greater_than_equal_u32(loc_1199_, loc_1206_) then
													loc_1191_ = loc_1195_;
													loc_1196_ = loc_1198_;
													loc_1197_ = loc_1190_;
													loc_1198_ = loc_1199_;
													loc_1199_ = loc_1200_;
													loc_1200_ = loc_1201_;
												else
													loc_1191_ = loc_1195_;
													loc_1196_ = loc_1198_;
													loc_1197_ = loc_1190_;
													loc_1198_ = loc_1199_;
													loc_1199_ = loc_1200_;
													loc_1200_ = loc_1201_;
													rt_store_i32(loc_1193_, 0, 71980, loc_1198_)
												end
												loc_1201_ = bit32_or(loc_1198_ + loc_1199_, 0);
												loc_1206_ = 72412;
												repeat
													rt_yield_budget = rt_yield_budget - 1
													if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
													loc_1196_ = buffer_read_i32(loc_1193_[1], loc_1206_, 0);
													if rt_equal_i32(loc_1196_, loc_1201_) then
														loc_1195_ = 0;
														loc_1202_ = 1;
													else
														loc_1206_ = buffer_read_i32(loc_1193_[1], loc_1206_, 8);
														if rt_not_equal_i32(loc_1206_, 0) then
															loc_1195_ = 1;
															loc_1202_ = 65535;
														else
															loc_1195_ = 0;
															loc_1202_ = 0;
														end
													end
													loc_1203_ = loc_1195_;
												until loc_1195_ == 0
												if rt_not_equal_i32(loc_1202_, 0) then
													loc_1195_ = rt_load_i32_from_u8(loc_1193_, loc_1206_, 12);
													if rt_equal_i32(rt_and_i32(loc_1195_, 8), 0) then
														loc_1195_ = loc_1191_;
														rt_store_i32(loc_1193_, loc_1206_, 0, loc_1198_)
														loc_1190_ = buffer_read_i32(loc_1193_[1], loc_1206_, 4);
														rt_store_i32(loc_1193_, loc_1206_, 4, bit32_or(loc_1190_ + loc_1199_, 0))
														loc_1191_ = loc_1191_[1](loc_1198_, loc_1196_, loc_1205_, loc_1197_)
														loc_1197_ = 1;
													else
														loc_1196_, loc_1206_ = loc_1206_, loc_1196_;
														loc_1206_, loc_1197_ = loc_1197_, loc_1206_;
														loc_1195_ = loc_1191_;
														loc_1197_ = 0;
														loc_1191_ = loc_1196_;
														loc_1190_ = loc_1206_;
													end
												else
													loc_1196_, loc_1206_ = loc_1206_, loc_1196_;
													loc_1206_, loc_1197_ = loc_1197_, loc_1206_;
													loc_1195_ = loc_1191_;
													loc_1197_ = 0;
													loc_1191_ = loc_1196_;
													loc_1190_ = loc_1206_;
												end
												if rt_not_equal_i32(loc_1197_, 0) then
													loc_1203_ = 1;
												else
													loc_1197_ = loc_1191_;
													loc_1198_, loc_1199_ = loc_1199_, loc_1198_;
													loc_1200_, loc_1201_ = loc_1201_, loc_1200_;
													loc_1202_, loc_1203_ = loc_1203_, loc_1202_;
													loc_1197_ = 72412;
													repeat
														rt_yield_budget = rt_yield_budget - 1
														if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
														loc_1200_ = buffer_read_i32(loc_1193_[1], loc_1197_, 0);
														if rt_less_than_u32(loc_1201_, loc_1200_) then
															loc_1196_ = loc_1202_;
															loc_1202_ = 0;
														else
															loc_1196_ = loc_1202_;
															loc_1202_ = buffer_read_i32(loc_1193_[1], loc_1197_, 4);
															loc_1200_ = bit32_or(loc_1200_ + loc_1202_, 0);
															if rt_less_than_u32(loc_1201_, loc_1200_) then
																loc_1202_ = loc_1196_;
																loc_1202_ = 1;
																loc_1196_ = 0;
															else
																loc_1202_ = 0;
															end
														end
														if not (rt_not_equal_i32(loc_1202_, 0)) then
															loc_1202_ = loc_1203_;
															loc_1203_ = loc_1196_;
															loc_1197_ = buffer_read_i32(loc_1193_[1], loc_1197_, 8);
															loc_1196_ = 1;
															loc_1203_ = 65535;
														end
														loc_1202_ = loc_1196_;
													until loc_1196_ == 0
													loc_1196_ = rt_and_i32(bit32_or(-8 - loc_1199_, 0), 15);
													loc_1197_ = bit32_or(loc_1199_ + loc_1196_, 0);
													loc_1202_ = bit32_or(loc_1198_ + -56, 0);
													loc_1196_ = bit32_or(loc_1202_ - loc_1196_, 0);
													rt_store_i32(loc_1193_, loc_1197_, 4, rt_or_i32(loc_1196_, 1))
													rt_store_i32(loc_1193_, bit32_or(loc_1199_ + loc_1202_, 0), 4, 56)
													loc_1191_ = bit32_or(bit32_or(loc_1200_ + rt_and_i32(bit32_or(55 - loc_1200_, 0), 15), 0) + -63, 0);
													if rt_less_than_u32(loc_1191_, bit32_or(loc_1201_ + 16, 0)) then
														loc_1202_ = loc_1201_;
													else
														loc_1202_ = loc_1201_;
														loc_1201_ = loc_1191_;
													end
													rt_store_i32(loc_1193_, loc_1201_, 4, 35)
													loc_1191_ = buffer_read_i32(loc_1193_[1], 0, 72452);
													rt_store_i32(loc_1193_, 0, 71992, loc_1191_)
													rt_store_i32(loc_1193_, 0, 71976, loc_1196_)
													rt_store_i32(loc_1193_, 0, 71988, loc_1197_)
													loc_1197_ = rt_load_i64(loc_1193_, 0, 72420);
													rt_store_i64(loc_1193_, bit32_or(loc_1201_ + 16, 0), 0, loc_1197_)
													loc_1197_ = rt_load_i64(loc_1193_, 0, 72412);
													rt_store_i64(loc_1193_, loc_1201_, 8, loc_1197_)
													rt_store_i32(loc_1193_, 0, 72420, bit32_or(loc_1201_ + 8, 0))
													rt_store_i32(loc_1193_, 0, 72416, loc_1198_)
													rt_store_i32(loc_1193_, 0, 72412, loc_1199_)
													rt_store_i32(loc_1193_, 0, 72424, 0)
													loc_1191_ = bit32_or(loc_1201_ + 36, 0);
													repeat
														rt_yield_budget = rt_yield_budget - 1
														if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
														loc_1198_ = loc_1200_;
														rt_store_i32(loc_1193_, loc_1191_, 0, 7)
														loc_1200_ = loc_1198_;
														loc_1199_ = bit32_or(loc_1191_ + 4, 0);
														loc_1191_ = loc_1199_;
													until not (rt_less_than_u32(loc_1199_, loc_1198_))
													if rt_equal_i32(loc_1201_, loc_1202_) then
														loc_1203_ = 0;
													else
														loc_1200_ = loc_1191_;
														loc_1200_ = buffer_read_i32(loc_1193_[1], loc_1201_, 4);
														rt_store_i32(loc_1193_, loc_1201_, 4, rt_and_i32(loc_1200_, -2))
														loc_1196_ = bit32_or(loc_1201_ - loc_1202_, 0);
														rt_store_i32(loc_1193_, loc_1201_, 0, loc_1196_)
														rt_store_i32(loc_1193_, loc_1202_, 4, rt_or_i32(loc_1196_, 1))
														if rt_greater_than_u32(loc_1196_, 255) then
															loc_1197_ = loc_1203_;
															loc_1199_ = 31;
															if not (rt_greater_than_u32(loc_1196_, 16777215)) then
																loc_1203_ = loc_1199_;
																loc_1203_ = rt_leading_zeroes_i32(rt_shift_right_u32(loc_1196_, 8));
																loc_1199_ = bit32_or(bit32_or(rt_and_i32(rt_shift_right_u32(loc_1196_, bit32_or(38 - loc_1203_, 0)), 1) - rt_shift_left_i32(loc_1203_, 1), 0) + 62, 0);
															end
															rt_store_i32(loc_1193_, loc_1202_, 28, loc_1199_)
															rt_store_i64(loc_1193_, loc_1202_, 16, into_bits_i64(0, 0))
															loc_1203_ = buffer_read_i32(loc_1193_[1], 0, 71968);
															loc_1200_ = bit32_or(rt_shift_left_i32(loc_1199_, 2) + 72268, 0);
															loc_1201_ = rt_shift_left_i32(1, loc_1199_);
															if rt_not_equal_i32(rt_and_i32(loc_1203_, loc_1201_), 0) then
																loc_1203_ = 0;
																loc_1198_ = bit32_or(25 - rt_shift_right_u32(loc_1199_, 1), 0);
																if rt_equal_i32(loc_1199_, 31) then
																	loc_1199_ = loc_1196_;
																else
																	loc_1199_ = loc_1196_;
																	loc_1203_ = loc_1198_;
																end
																loc_1198_ = buffer_read_i32(loc_1193_[1], loc_1200_, 0);
																loc_1203_ = rt_shift_left_i32(loc_1196_, loc_1203_);
																repeat
																	rt_yield_budget = rt_yield_budget - 1
																	if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																	loc_1197_, loc_1200_ = loc_1200_, loc_1197_;
																	loc_1200_ = buffer_read_i32(loc_1193_[1], loc_1198_, 4);
																	if rt_equal_i32(rt_and_i32(loc_1200_, -8), loc_1199_) then
																		loc_1200_ = loc_1198_;
																		loc_1196_ = 0;
																		loc_1197_ = 1;
																	else
																		loc_1200_ = loc_1198_;
																		loc_1201_ = bit32_or(loc_1200_ + rt_and_i32(rt_shift_right_u32(loc_1203_, 29), 4), 0);
																		loc_1198_ = buffer_read_i32(loc_1193_[1], loc_1201_, 16);
																		loc_1203_ = rt_shift_left_i32(loc_1203_, 1);
																		if rt_not_equal_i32(loc_1198_, 0) then
																			loc_1196_ = 1;
																			loc_1197_ = 65535;
																		else
																			loc_1196_ = 0;
																			loc_1197_ = 0;
																		end
																	end
																until loc_1196_ == 0
																if rt_not_equal_i32(loc_1197_, 0) then
																	loc_1203_ = buffer_read_i32(loc_1193_[1], loc_1200_, 8);
																	rt_store_i32(loc_1193_, loc_1200_, 8, loc_1202_)
																	rt_store_i32(loc_1193_, loc_1203_, 12, loc_1202_)
																	rt_store_i32(loc_1193_, loc_1202_, 8, loc_1203_)
																	loc_1199_ = 1;
																	loc_1191_ = 0;
																	loc_1203_ = 24;
																	loc_1201_ = 12;
																else
																	loc_1199_, loc_1201_ = loc_1201_, loc_1199_;
																	loc_1201_, loc_1203_ = loc_1203_, loc_1201_;
																	rt_store_i32(loc_1193_, bit32_or(loc_1199_ + 16, 0), 0, loc_1202_)
																	rt_store_i32(loc_1193_, loc_1202_, 24, loc_1200_)
																	loc_1199_ = 0;
																	loc_1191_ = loc_1201_;
																	loc_1201_ = loc_1198_;
																end
															else
																loc_1198_ = loc_1197_;
																loc_1199_, loc_1201_ = loc_1201_, loc_1199_;
																loc_1201_, loc_1203_ = loc_1203_, loc_1201_;
																rt_store_i32(loc_1193_, loc_1200_, 0, loc_1202_)
																rt_store_i32(loc_1193_, 0, 71968, rt_or_i32(loc_1201_, loc_1199_))
																rt_store_i32(loc_1193_, loc_1202_, 24, loc_1200_)
																loc_1199_ = 0;
																loc_1191_ = loc_1203_;
																loc_1203_ = loc_1196_;
															end
															if not (rt_not_equal_i32(loc_1199_, 0)) then
																loc_1199_ = loc_1201_;
																loc_1201_ = loc_1191_;
																loc_1200_, loc_1203_ = loc_1203_, loc_1200_;
																loc_1203_, loc_1202_ = loc_1202_, loc_1203_;
																loc_1200_ = loc_1203_;
																loc_1202_ = loc_1203_;
																loc_1191_ = loc_1203_;
																loc_1203_ = 8;
																loc_1201_ = 12;
															end
														else
															loc_1203_ = buffer_read_i32(loc_1193_[1], 0, 71964);
															loc_1191_ = bit32_or(rt_and_i32(loc_1196_, -8) + 72004, 0);
															loc_1201_ = rt_shift_left_i32(1, rt_shift_right_u32(loc_1196_, 3));
															if rt_not_equal_i32(rt_and_i32(loc_1203_, loc_1201_), 0) then
																loc_1200_ = buffer_read_i32(loc_1193_[1], loc_1191_, 8);
															else
																rt_store_i32(loc_1193_, 0, 71964, rt_or_i32(loc_1203_, loc_1201_))
																loc_1200_ = loc_1191_;
															end
															rt_store_i32(loc_1193_, loc_1200_, 12, loc_1202_)
															rt_store_i32(loc_1193_, loc_1191_, 8, loc_1202_)
															loc_1203_ = 12;
															loc_1201_ = 8;
														end
														rt_store_i32(loc_1193_, bit32_or(loc_1202_ + loc_1201_, 0), 0, loc_1200_)
														rt_store_i32(loc_1193_, bit32_or(loc_1202_ + loc_1203_, 0), 0, loc_1191_)
														loc_1203_ = 0;
													end
												end
											end
										end
										if rt_not_equal_i32(loc_1203_, 0) then
											loc_1205_ = 1;
										else
											loc_1203_ = loc_1191_;
											loc_1191_ = buffer_read_i32(loc_1193_[1], 0, 71976);
											if rt_less_than_equal_u32(loc_1191_, loc_1205_) then
												loc_1205_ = 0;
											else
												loc_1203_ = buffer_read_i32(loc_1193_[1], 0, 71988);
												loc_1202_ = bit32_or(loc_1203_ + loc_1205_, 0);
												loc_1201_ = bit32_or(loc_1191_ - loc_1205_, 0);
												rt_store_i32(loc_1193_, loc_1202_, 4, rt_or_i32(loc_1201_, 1))
												rt_store_i32(loc_1193_, 0, 71976, loc_1201_)
												rt_store_i32(loc_1193_, 0, 71988, loc_1202_)
												rt_store_i32(loc_1193_, loc_1203_, 4, rt_or_i32(loc_1205_, 3))
												loc_1205_ = 1;
												loc_1191_ = bit32_or(loc_1203_ + 8, 0);
											end
										end
									end
									if not (rt_not_equal_i32(loc_1205_, 0)) then
										loc_1205_ = loc_1191_;
										rt_store_i32(loc_1193_, 0, 70852, 48)
										loc_1191_ = 0;
									end
								end
							else
								loc_1206_ = loc_1203_;
								loc_1203_ = loc_1201_;
								loc_1201_ = loc_1199_;
								loc_1199_ = loc_1197_;
								loc_1197_ = loc_1205_;
								loc_1205_ = loc_1202_;
								loc_1202_ = loc_1200_;
								loc_1200_ = loc_1198_;
								loc_1198_ = loc_1196_;
								rt_store_i32(loc_1193_, 0, 70852, 48)
								loc_1191_ = loc_1207_;
							end
						else
							loc_1206_ = loc_1202_;
							loc_1207_ = loc_1203_;
							loc_1206_ = bit32_or(loc_1200_ + loc_1199_, 0);
							loc_1207_ = bit32_or(loc_1201_ - loc_1199_, 0);
							rt_store_i32(loc_1193_, loc_1206_, 4, rt_or_i32(loc_1207_, 1))
							rt_store_i32(loc_1193_, 0, 71988, loc_1206_)
							rt_store_i32(loc_1193_, 0, 71976, loc_1207_)
							rt_store_i32(loc_1193_, loc_1200_, 4, rt_or_i32(loc_1199_, 3))
							loc_1191_ = bit32_or(loc_1200_ + 8, 0);
						end
					else
						loc_1199_ = loc_1200_;
						loc_1205_ = loc_1202_;
						loc_1206_ = loc_1207_;
						loc_1207_ = loc_1203_;
						loc_1203_ = loc_1201_;
						loc_1207_ = buffer_read_i32(loc_1193_[1], 0, 71984);
						loc_1205_ = bit32_or(loc_1206_ - loc_1199_, 0);
						if rt_less_than_u32(loc_1205_, 16) then
							loc_1203_ = loc_1199_;
							rt_store_i32(loc_1193_, loc_1207_, 4, rt_or_i32(loc_1206_, 3))
							loc_1205_ = bit32_or(loc_1207_ + loc_1206_, 0);
							loc_1206_ = buffer_read_i32(loc_1193_[1], loc_1205_, 4);
							rt_store_i32(loc_1193_, loc_1205_, 4, rt_or_i32(loc_1206_, 1))
							loc_1205_ = 0;
							loc_1206_ = 0;
						else
							loc_1202_ = loc_1206_;
							loc_1203_ = loc_1199_;
							loc_1206_ = bit32_or(loc_1207_ + loc_1203_, 0);
							rt_store_i32(loc_1193_, loc_1206_, 4, rt_or_i32(loc_1205_, 1))
							rt_store_i32(loc_1193_, bit32_or(loc_1207_ + loc_1202_, 0), 0, loc_1205_)
							rt_store_i32(loc_1193_, loc_1207_, 4, rt_or_i32(loc_1203_, 3))
						end
						rt_store_i32(loc_1193_, 0, 71972, loc_1205_)
						rt_store_i32(loc_1193_, 0, 71984, loc_1206_)
						loc_1191_ = bit32_or(loc_1207_ + 8, 0);
					end
				end
				loc_1192_[1] = bit32_or(loc_1204_ + 16, 0);
			end
			return loc_1191_, loc_1190_
		end), "i32->i32")
	end)(module_locals[105], module_locals[108], module_locals[114], module_locals[3]);
	module_locals[108][1] = (function(loc_1210_)
		return rt_function_type((function(loc_1211_, loc_1212_, loc_1213_, loc_1214_)
			local loc_1215_, loc_1216_, loc_1217_, loc_1218_, loc_1219_, loc_1220_, loc_1221_, loc_1222_, loc_1223_, loc_1224_, loc_1225_, loc_1226_, loc_1227_, loc_1228_
			loc_1216_ = bit32_or(loc_1211_ + rt_and_i32(bit32_or(-8 - loc_1211_, 0), 15), 0);
			rt_store_i32(loc_1210_, loc_1216_, 4, rt_or_i32(loc_1213_, 3))
			loc_1217_ = loc_1210_;
			loc_1228_ = buffer_read_i32(loc_1217_[1], 0, 71988);
			loc_1221_ = 0;
			loc_1225_ = bit32_or(loc_1212_ + rt_and_i32(bit32_or(-8 - loc_1212_, 0), 15), 0);
			loc_1219_ = bit32_or(loc_1216_ + loc_1213_, 0);
			loc_1223_ = bit32_or(loc_1225_ - loc_1219_, 0);
			loc_1222_ = 0;
			loc_1220_ = 0;
			if rt_not_equal_i32(loc_1225_, loc_1228_) then
				loc_1215_ = loc_1214_;
				loc_1228_ = buffer_read_i32(loc_1217_[1], 0, 71984);
				if rt_not_equal_i32(loc_1225_, loc_1228_) then
					loc_1224_ = buffer_read_i32(loc_1217_[1], loc_1225_, 4);
					if not (rt_not_equal_i32(rt_and_i32(loc_1224_, 3), 1)) then
						loc_1228_ = buffer_read_i32(loc_1217_[1], loc_1225_, 12);
						loc_1227_ = rt_and_i32(loc_1224_, -8);
						if rt_greater_than_u32(loc_1224_, 255) then
							loc_1218_ = loc_1220_;
							loc_1226_ = loc_1222_;
							loc_1222_ = loc_1223_;
							loc_1223_ = loc_1227_;
							loc_1227_ = loc_1224_;
							loc_1220_ = buffer_read_i32(loc_1217_[1], loc_1225_, 24);
							if rt_equal_i32(loc_1228_, loc_1225_) then
								loc_1227_ = buffer_read_i32(loc_1217_[1], loc_1225_, 20);
								if rt_equal_i32(loc_1227_, 0) then
									loc_1227_ = buffer_read_i32(loc_1217_[1], loc_1225_, 16);
									if rt_equal_i32(loc_1227_, 0) then
										loc_1228_ = 1;
										loc_1224_ = 0;
									else
										loc_1225_, loc_1228_ = loc_1228_, loc_1225_;
										loc_1228_, loc_1226_ = loc_1226_, loc_1228_;
										loc_1228_ = 0;
										loc_1224_ = loc_1225_;
										loc_1225_ = loc_1226_;
										loc_1226_ = bit32_or(loc_1226_ + 16, 0);
									end
								else
									loc_1225_, loc_1228_ = loc_1228_, loc_1225_;
									loc_1228_, loc_1226_ = loc_1226_, loc_1228_;
									loc_1228_ = 0;
									loc_1224_ = loc_1225_;
									loc_1225_ = loc_1226_;
									loc_1226_ = bit32_or(loc_1226_ + 20, 0);
								end
								if not (rt_not_equal_i32(loc_1228_, 0)) then
									loc_1228_ = loc_1218_;
									loc_1226_, loc_1227_ = loc_1227_, loc_1226_;
									loc_1218_ = loc_1227_;
									loc_1227_ = loc_1228_;
									repeat
										rt_yield_budget = rt_yield_budget - 1
										if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
										loc_1228_ = loc_1218_;
										loc_1224_, loc_1227_ = loc_1227_, loc_1224_;
										loc_1227_, loc_1226_ = loc_1226_, loc_1227_;
										loc_1226_ = buffer_read_i32(loc_1217_[1], loc_1227_, 20);
										loc_1218_ = bit32_or(loc_1227_ + 20, 0);
										if rt_not_equal_i32(loc_1226_, 0) then
											loc_1224_ = loc_1227_;
											loc_1227_ = loc_1228_;
											loc_1228_ = loc_1221_;
											loc_1228_ = 1;
											loc_1221_ = 65535;
										else
											loc_1224_ = loc_1227_;
											loc_1227_ = loc_1228_;
											loc_1228_ = loc_1221_;
											loc_1221_ = loc_1218_;
											loc_1226_ = buffer_read_i32(loc_1217_[1], loc_1224_, 16);
											loc_1218_ = bit32_or(loc_1224_ + 16, 0);
											if rt_not_equal_i32(loc_1226_, 0) then
												loc_1228_ = 1;
												loc_1221_ = 65535;
											else
												loc_1221_ = loc_1228_;
												loc_1228_ = 0;
											end
										end
									until loc_1228_ == 0
									rt_store_i32(loc_1217_, loc_1227_, 0, 0)
								end
							else
								loc_1227_ = loc_1226_;
								loc_1226_ = loc_1218_;
								loc_1227_ = buffer_read_i32(loc_1217_[1], loc_1225_, 8);
								rt_store_i32(loc_1217_, loc_1227_, 12, loc_1228_)
								rt_store_i32(loc_1217_, loc_1228_, 8, loc_1227_)
								loc_1224_ = loc_1228_;
							end
							if not (rt_equal_i32(loc_1220_, 0)) then
								loc_1226_ = buffer_read_i32(loc_1217_[1], loc_1225_, 28);
								loc_1218_ = rt_shift_left_i32(loc_1226_, 2);
								loc_1227_ = buffer_read_i32(loc_1217_[1], loc_1218_, 72268);
								if rt_not_equal_i32(loc_1225_, loc_1227_) then
									loc_1218_ = buffer_read_i32(loc_1217_[1], loc_1220_, 16);
									if rt_not_equal_i32(loc_1218_, loc_1225_) then
										rt_store_i32(loc_1217_, loc_1220_, 20, loc_1224_)
									else
										rt_store_i32(loc_1217_, loc_1220_, 16, loc_1224_)
									end
									if rt_equal_i32(loc_1224_, 0) then
										loc_1218_ = 1;
									else
										loc_1218_ = 0;
									end
								else
									rt_store_i32(loc_1217_, bit32_or(loc_1218_ + 72268, 0), 0, loc_1224_)
									if rt_not_equal_i32(loc_1224_, 0) then
										loc_1218_ = 0;
									else
										loc_1218_ = buffer_read_i32(loc_1217_[1], 0, 71968);
										rt_store_i32(loc_1217_, 0, 71968, rt_and_i32(loc_1218_, rt_rotate_left_i32(-2, loc_1226_)))
										loc_1218_ = 1;
									end
								end
								if not (rt_not_equal_i32(loc_1218_, 0)) then
									loc_1220_, loc_1224_ = loc_1224_, loc_1220_;
									rt_store_i32(loc_1217_, loc_1220_, 24, loc_1224_)
									loc_1224_ = buffer_read_i32(loc_1217_[1], loc_1225_, 16);
									if not (rt_equal_i32(loc_1224_, 0)) then
										rt_store_i32(loc_1217_, loc_1220_, 16, loc_1224_)
										rt_store_i32(loc_1217_, loc_1224_, 24, loc_1220_)
									end
									loc_1224_ = buffer_read_i32(loc_1217_[1], loc_1225_, 20);
									if not (rt_equal_i32(loc_1224_, 0)) then
										rt_store_i32(loc_1217_, loc_1220_, 20, loc_1224_)
										rt_store_i32(loc_1217_, loc_1224_, 24, loc_1220_)
									end
								end
							end
						else
							loc_1226_ = loc_1222_;
							loc_1222_ = loc_1223_;
							loc_1223_ = loc_1227_;
							loc_1227_ = loc_1224_;
							loc_1224_ = loc_1220_;
							loc_1226_ = buffer_read_i32(loc_1217_[1], loc_1225_, 8);
							if rt_not_equal_i32(loc_1228_, loc_1226_) then
								loc_1226_, loc_1227_ = loc_1227_, loc_1226_;
								loc_1227_, loc_1228_ = loc_1228_, loc_1227_;
								rt_store_i32(loc_1217_, loc_1227_, 8, loc_1228_)
								rt_store_i32(loc_1217_, loc_1228_, 12, loc_1227_)
							else
								loc_1226_, loc_1227_ = loc_1227_, loc_1226_;
								loc_1228_ = buffer_read_i32(loc_1217_[1], 0, 71964);
								rt_store_i32(loc_1217_, 0, 71964, rt_and_i32(loc_1228_, rt_rotate_left_i32(-2, rt_shift_right_u32(loc_1226_, 3))))
							end
						end
						loc_1225_ = bit32_or(loc_1225_ + loc_1223_, 0);
						loc_1224_ = buffer_read_i32(loc_1217_[1], loc_1225_, 4);
						loc_1223_ = bit32_or(loc_1223_ + loc_1222_, 0);
					end
					rt_store_i32(loc_1217_, loc_1225_, 4, rt_and_i32(loc_1224_, -2))
					rt_store_i32(loc_1217_, bit32_or(loc_1219_ + loc_1223_, 0), 0, loc_1223_)
					rt_store_i32(loc_1217_, loc_1219_, 4, rt_or_i32(loc_1223_, 1))
					if rt_greater_than_u32(loc_1223_, 255) then
						loc_1222_ = 31;
						if not (rt_greater_than_u32(loc_1223_, 16777215)) then
							loc_1224_ = loc_1223_;
							loc_1225_ = loc_1222_;
							loc_1223_ = loc_1224_;
							loc_1225_ = rt_leading_zeroes_i32(rt_shift_right_u32(loc_1224_, 8));
							loc_1222_ = bit32_or(bit32_or(rt_and_i32(rt_shift_right_u32(loc_1224_, bit32_or(38 - loc_1225_, 0)), 1) - rt_shift_left_i32(loc_1225_, 1), 0) + 62, 0);
						end
						rt_store_i32(loc_1217_, loc_1219_, 28, loc_1222_)
						rt_store_i64(loc_1217_, loc_1219_, 16, into_bits_i64(0, 0))
						loc_1225_ = buffer_read_i32(loc_1217_[1], 0, 71968);
						loc_1220_ = bit32_or(rt_shift_left_i32(loc_1222_, 2) + 72268, 0);
						loc_1218_ = rt_shift_left_i32(1, loc_1222_);
						if rt_not_equal_i32(rt_and_i32(loc_1225_, loc_1218_), 0) then
							loc_1225_ = 0;
							loc_1224_ = bit32_or(25 - rt_shift_right_u32(loc_1222_, 1), 0);
							if rt_equal_i32(loc_1222_, 31) then
								loc_1222_ = loc_1223_;
							else
								loc_1222_ = loc_1223_;
								loc_1225_ = loc_1224_;
							end
							loc_1224_ = buffer_read_i32(loc_1217_[1], loc_1220_, 0);
							loc_1223_ = rt_shift_left_i32(loc_1223_, loc_1225_);
							repeat
								rt_yield_budget = rt_yield_budget - 1
								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
								loc_1225_ = loc_1221_;
								loc_1221_ = loc_1220_;
								loc_1225_ = buffer_read_i32(loc_1217_[1], loc_1224_, 4);
								if rt_equal_i32(rt_and_i32(loc_1225_, -8), loc_1222_) then
									loc_1220_ = loc_1224_;
									loc_1225_ = 0;
									loc_1221_ = 1;
								else
									loc_1220_ = loc_1224_;
									loc_1225_ = loc_1218_;
									loc_1218_ = bit32_or(loc_1220_ + rt_and_i32(rt_shift_right_u32(loc_1223_, 29), 4), 0);
									loc_1224_ = buffer_read_i32(loc_1217_[1], loc_1218_, 16);
									loc_1223_ = rt_shift_left_i32(loc_1223_, 1);
									if rt_not_equal_i32(loc_1224_, 0) then
										loc_1225_ = 1;
										loc_1221_ = 65535;
									else
										loc_1225_ = 0;
										loc_1221_ = 0;
									end
								end
							until loc_1225_ == 0
							if rt_not_equal_i32(loc_1221_, 0) then
								loc_1218_ = buffer_read_i32(loc_1217_[1], loc_1220_, 8);
								rt_store_i32(loc_1217_, loc_1218_, 12, loc_1219_)
								rt_store_i32(loc_1217_, loc_1220_, 8, loc_1219_)
								rt_store_i32(loc_1217_, loc_1219_, 24, 0)
								rt_store_i32(loc_1217_, loc_1219_, 12, loc_1220_)
								rt_store_i32(loc_1217_, loc_1219_, 8, loc_1218_)
							else
								rt_store_i32(loc_1217_, bit32_or(loc_1218_ + 16, 0), 0, loc_1219_)
								rt_store_i32(loc_1217_, loc_1219_, 24, loc_1220_)
								rt_store_i32(loc_1217_, loc_1219_, 12, loc_1219_)
								rt_store_i32(loc_1217_, loc_1219_, 8, loc_1219_)
							end
						else
							loc_1224_ = loc_1221_;
							rt_store_i32(loc_1217_, loc_1220_, 0, loc_1219_)
							rt_store_i32(loc_1217_, 0, 71968, rt_or_i32(loc_1225_, loc_1218_))
							rt_store_i32(loc_1217_, loc_1219_, 24, loc_1220_)
							rt_store_i32(loc_1217_, loc_1219_, 8, loc_1219_)
							rt_store_i32(loc_1217_, loc_1219_, 12, loc_1219_)
						end
					else
						loc_1225_ = loc_1221_;
						loc_1222_ = buffer_read_i32(loc_1217_[1], 0, 71964);
						loc_1224_ = rt_shift_left_i32(1, rt_shift_right_u32(loc_1223_, 3));
						loc_1223_ = bit32_or(rt_and_i32(loc_1223_, -8) + 72004, 0);
						if rt_not_equal_i32(rt_and_i32(loc_1222_, loc_1224_), 0) then
							loc_1225_ = loc_1219_;
							loc_1224_ = buffer_read_i32(loc_1217_[1], loc_1223_, 8);
						else
							loc_1225_ = loc_1219_;
							rt_store_i32(loc_1217_, 0, 71964, rt_or_i32(loc_1222_, loc_1224_))
							loc_1224_ = loc_1223_;
						end
						rt_store_i32(loc_1217_, loc_1224_, 12, loc_1225_)
						rt_store_i32(loc_1217_, loc_1223_, 8, loc_1225_)
						rt_store_i32(loc_1217_, loc_1225_, 12, loc_1223_)
						rt_store_i32(loc_1217_, loc_1225_, 8, loc_1224_)
					end
				else
					loc_1226_ = loc_1222_;
					loc_1227_ = loc_1225_;
					loc_1225_ = loc_1220_;
					loc_1228_ = loc_1221_;
					rt_store_i32(loc_1217_, 0, 71984, loc_1219_)
					loc_1228_ = buffer_read_i32(loc_1217_[1], 0, 71972);
					loc_1228_ = bit32_or(loc_1228_ + loc_1223_, 0);
					rt_store_i32(loc_1217_, 0, 71972, loc_1228_)
					rt_store_i32(loc_1217_, loc_1219_, 4, rt_or_i32(loc_1228_, 1))
					rt_store_i32(loc_1217_, bit32_or(loc_1219_ + loc_1228_, 0), 0, loc_1228_)
				end
			else
				loc_1215_ = loc_1214_;
				loc_1226_ = loc_1222_;
				loc_1227_ = loc_1225_;
				loc_1225_ = loc_1220_;
				loc_1228_ = loc_1221_;
				rt_store_i32(loc_1217_, 0, 71988, loc_1219_)
				loc_1228_ = buffer_read_i32(loc_1217_[1], 0, 71976);
				loc_1228_ = bit32_or(loc_1228_ + loc_1223_, 0);
				rt_store_i32(loc_1217_, 0, 71976, loc_1228_)
				rt_store_i32(loc_1217_, loc_1219_, 4, rt_or_i32(loc_1228_, 1))
			end
			return bit32_or(loc_1216_ + 8, 0), loc_1215_
		end), "i32,i32,i32->i32")
	end)(module_locals[3]);
	module_locals[110] = { nil };
	module_locals[109][1] = (function(loc_1229_)
		return rt_function_type((function(loc_1230_, loc_1231_)
			local loc_1232_
			loc_1232_ = loc_1231_;
			loc_1229_[1](loc_1230_, loc_1232_)
			return loc_1232_
		end), "i32->")
	end)(module_locals[110]);
	module_locals[110][1] = (function(loc_1233_)
		return rt_function_type((function(loc_1234_, loc_1235_)
			local loc_1236_, loc_1237_, loc_1238_, loc_1239_, loc_1240_, loc_1241_, loc_1242_, loc_1243_, loc_1244_, loc_1245_, loc_1246_, loc_1247_, loc_1248_
			loc_1238_ = 0;
			loc_1240_ = 0;
			loc_1241_ = 0;
			if rt_equal_i32(loc_1234_, 0) then
				loc_1236_ = loc_1235_;
				loc_1237_ = loc_1233_;
				loc_1239_ = loc_1234_;
				loc_1238_ = 0;
			else
				loc_1236_ = loc_1235_;
				loc_1237_ = loc_1233_;
				loc_1239_ = loc_1234_;
				loc_1246_ = loc_1240_;
				loc_1248_ = buffer_read_i32(loc_1237_[1], bit32_or(loc_1239_ + -4, 0), 0);
				loc_1240_ = rt_and_i32(loc_1248_, -8);
				loc_1239_ = bit32_or(loc_1239_ + -8, 0);
				loc_1247_ = bit32_or(loc_1239_ + loc_1240_, 0);
				if rt_not_equal_i32(rt_and_i32(loc_1248_, 1), 0) then
					loc_1242_ = loc_1246_;
					loc_1243_ = loc_1241_;
					loc_1241_ = loc_1238_;
					loc_1238_ = loc_1247_;
					loc_1248_ = 0;
				else
					loc_1242_ = loc_1246_;
					loc_1243_ = loc_1241_;
					loc_1241_ = loc_1238_;
					loc_1238_ = loc_1247_;
					if rt_equal_i32(rt_and_i32(loc_1248_, 2), 0) then
						loc_1248_ = 1;
					else
						loc_1248_ = buffer_read_i32(loc_1237_[1], loc_1239_, 0);
						loc_1247_ = buffer_read_i32(loc_1237_[1], 0, 71980);
						loc_1239_ = bit32_or(loc_1239_ - loc_1248_, 0);
						if rt_less_than_u32(loc_1239_, loc_1247_) then
							loc_1248_ = 2;
						else
							loc_1247_ = buffer_read_i32(loc_1237_[1], 0, 71984);
							loc_1240_ = bit32_or(loc_1248_ + loc_1240_, 0);
							if rt_equal_i32(loc_1239_, loc_1247_) then
								loc_1248_ = buffer_read_i32(loc_1237_[1], loc_1238_, 4);
								if rt_not_equal_i32(rt_and_i32(loc_1248_, 3), 3) then
									loc_1248_ = 0;
								else
									rt_store_i32(loc_1237_, loc_1238_, 4, rt_and_i32(loc_1248_, -2))
									rt_store_i32(loc_1237_, 0, 71972, loc_1240_)
									rt_store_i32(loc_1237_, loc_1238_, 0, loc_1240_)
									rt_store_i32(loc_1237_, loc_1239_, 4, rt_or_i32(loc_1240_, 1))
									loc_1248_ = 3;
								end
							else
								loc_1247_ = loc_1248_;
								loc_1248_ = buffer_read_i32(loc_1237_[1], loc_1239_, 12);
								if rt_greater_than_u32(loc_1247_, 255) then
									loc_1247_ = buffer_read_i32(loc_1237_[1], loc_1239_, 24);
									if rt_equal_i32(loc_1248_, loc_1239_) then
										loc_1246_ = buffer_read_i32(loc_1237_[1], loc_1239_, 20);
										if rt_equal_i32(loc_1246_, 0) then
											loc_1246_ = buffer_read_i32(loc_1237_[1], loc_1239_, 16);
											if rt_equal_i32(loc_1246_, 0) then
												loc_1245_ = 1;
												loc_1248_ = 0;
											else
												loc_1244_ = loc_1239_;
												loc_1245_ = loc_1242_;
												loc_1245_ = 0;
												loc_1239_ = loc_1244_;
												loc_1242_ = bit32_or(loc_1244_ + 16, 0);
											end
										else
											loc_1244_ = loc_1239_;
											loc_1245_ = loc_1242_;
											loc_1245_ = 0;
											loc_1239_ = loc_1244_;
											loc_1242_ = bit32_or(loc_1244_ + 20, 0);
										end
										if not (rt_not_equal_i32(loc_1245_, 0)) then
											repeat
												rt_yield_budget = rt_yield_budget - 1
												if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
												loc_1244_ = loc_1243_;
												loc_1245_ = loc_1242_;
												loc_1248_ = buffer_read_i32(loc_1237_[1], loc_1246_, 20);
												loc_1242_ = bit32_or(loc_1246_ + 20, 0);
												if rt_not_equal_i32(loc_1248_, 0) then
													loc_1243_ = loc_1245_;
													loc_1245_ = loc_1241_;
													loc_1246_, loc_1248_ = loc_1248_, loc_1246_;
													loc_1245_ = 1;
													loc_1241_ = 65535;
												else
													loc_1243_ = loc_1245_;
													loc_1244_ = loc_1242_;
													loc_1245_ = loc_1241_;
													loc_1246_, loc_1248_ = loc_1248_, loc_1246_;
													loc_1246_ = buffer_read_i32(loc_1237_[1], loc_1248_, 16);
													loc_1242_ = bit32_or(loc_1248_ + 16, 0);
													if rt_not_equal_i32(loc_1246_, 0) then
														loc_1245_ = 1;
														loc_1241_ = 65535;
													else
														loc_1244_ = loc_1245_;
														loc_1245_ = 0;
														loc_1241_ = loc_1244_;
													end
												end
											until loc_1245_ == 0
											rt_store_i32(loc_1237_, loc_1243_, 0, 0)
										end
									else
										loc_1246_ = buffer_read_i32(loc_1237_[1], loc_1239_, 8);
										rt_store_i32(loc_1237_, loc_1246_, 12, loc_1248_)
										rt_store_i32(loc_1237_, loc_1248_, 8, loc_1246_)
									end
									if rt_equal_i32(loc_1247_, 0) then
										loc_1248_ = 0;
									else
										loc_1246_ = loc_1242_;
										loc_1242_ = buffer_read_i32(loc_1237_[1], loc_1239_, 28);
										loc_1246_ = rt_shift_left_i32(loc_1242_, 2);
										loc_1245_ = buffer_read_i32(loc_1237_[1], loc_1246_, 72268);
										if rt_not_equal_i32(loc_1239_, loc_1245_) then
											loc_1246_ = buffer_read_i32(loc_1237_[1], loc_1247_, 16);
											if rt_not_equal_i32(loc_1246_, loc_1239_) then
												rt_store_i32(loc_1237_, loc_1247_, 20, loc_1248_)
											else
												rt_store_i32(loc_1237_, loc_1247_, 16, loc_1248_)
											end
											if rt_equal_i32(loc_1248_, 0) then
												loc_1246_ = 2;
											else
												loc_1246_ = 0;
											end
										else
											rt_store_i32(loc_1237_, bit32_or(loc_1246_ + 72268, 0), 0, loc_1248_)
											if rt_not_equal_i32(loc_1248_, 0) then
												loc_1246_ = 0;
											else
												loc_1246_ = buffer_read_i32(loc_1237_[1], 0, 71968);
												rt_store_i32(loc_1237_, 0, 71968, rt_and_i32(loc_1246_, rt_rotate_left_i32(-2, loc_1242_)))
												loc_1246_ = 1;
											end
										end
										if (loc_1246_) >= 0 and (loc_1246_) < 2 then
											if (loc_1246_) < 1 then
												rt_store_i32(loc_1237_, loc_1248_, 24, loc_1247_)
												loc_1247_ = buffer_read_i32(loc_1237_[1], loc_1239_, 16);
												if not (rt_equal_i32(loc_1247_, 0)) then
													rt_store_i32(loc_1237_, loc_1248_, 16, loc_1247_)
													rt_store_i32(loc_1237_, loc_1247_, 24, loc_1248_)
												end
												loc_1247_ = buffer_read_i32(loc_1237_[1], loc_1239_, 20);
												if rt_equal_i32(loc_1247_, 0) then
													loc_1248_ = 0;
												else
													rt_store_i32(loc_1237_, loc_1248_, 20, loc_1247_)
													rt_store_i32(loc_1237_, loc_1247_, 24, loc_1248_)
													loc_1248_ = 0;
												end
											else
												loc_1248_ = 0;
											end
										else
											loc_1248_ = 0;
										end
									end
								else
									loc_1246_ = loc_1242_;
									loc_1242_ = buffer_read_i32(loc_1237_[1], loc_1239_, 8);
									if rt_not_equal_i32(loc_1248_, loc_1242_) then
										rt_store_i32(loc_1237_, loc_1248_, 8, loc_1242_)
										rt_store_i32(loc_1237_, loc_1242_, 12, loc_1248_)
										loc_1248_ = 0;
									else
										loc_1248_ = buffer_read_i32(loc_1237_[1], 0, 71964);
										rt_store_i32(loc_1237_, 0, 71964, rt_and_i32(loc_1248_, rt_rotate_left_i32(-2, rt_shift_right_u32(loc_1247_, 3))))
										loc_1248_ = 0;
									end
								end
							end
						end
					end
				end
				if (loc_1248_) >= 0 and (loc_1248_) < 3 then
					if (loc_1248_) < 1 then
						if rt_greater_than_equal_u32(loc_1239_, loc_1238_) then
							loc_1238_, loc_1243_ = loc_1243_, loc_1238_;
							loc_1243_, loc_1241_ = loc_1241_, loc_1243_;
							loc_1241_, loc_1239_ = loc_1239_, loc_1241_;
							loc_1239_, loc_1242_ = loc_1242_, loc_1239_;
							loc_1242_, loc_1240_ = loc_1240_, loc_1242_;
							loc_1238_ = 0;
						else
							loc_1248_ = loc_1242_;
							loc_1242_ = loc_1240_;
							loc_1240_ = loc_1238_;
							loc_1238_ = loc_1243_;
							loc_1243_ = loc_1241_;
							loc_1241_ = loc_1239_;
							loc_1239_ = buffer_read_i32(loc_1237_[1], loc_1240_, 4);
							if rt_equal_i32(rt_and_i32(loc_1239_, 1), 0) then
								loc_1244_ = loc_1238_;
								loc_1238_ = loc_1248_;
								loc_1238_ = 0;
							else
								loc_1244_ = loc_1238_;
								loc_1238_ = loc_1248_;
								if rt_not_equal_i32(rt_and_i32(loc_1239_, 2), 0) then
									loc_1245_ = loc_1240_;
									loc_1240_ = loc_1244_;
									loc_1244_ = loc_1243_;
									loc_1243_ = loc_1242_;
									loc_1242_ = loc_1241_;
									loc_1241_ = loc_1238_;
									loc_1246_ = loc_1239_;
									rt_store_i32(loc_1237_, loc_1245_, 4, rt_and_i32(loc_1246_, -2))
									rt_store_i32(loc_1237_, bit32_or(loc_1242_ + loc_1243_, 0), 0, loc_1243_)
									rt_store_i32(loc_1237_, loc_1242_, 4, rt_or_i32(loc_1243_, 1))
									loc_1246_ = 0;
								else
									loc_1245_ = loc_1240_;
									loc_1240_ = loc_1244_;
									loc_1244_ = loc_1243_;
									loc_1243_ = loc_1242_;
									loc_1242_ = loc_1241_;
									loc_1241_ = loc_1238_;
									loc_1246_ = loc_1239_;
									loc_1248_ = buffer_read_i32(loc_1237_[1], 0, 71988);
									if rt_not_equal_i32(loc_1245_, loc_1248_) then
										loc_1238_ = loc_1240_;
										loc_1239_ = loc_1241_;
										loc_1241_ = loc_1245_;
										loc_1245_ = loc_1243_;
										loc_1247_ = loc_1246_;
										loc_1246_ = buffer_read_i32(loc_1237_[1], 0, 71984);
										if rt_not_equal_i32(loc_1241_, loc_1246_) then
											loc_1248_ = buffer_read_i32(loc_1237_[1], loc_1241_, 12);
											loc_1243_ = bit32_or(rt_and_i32(loc_1247_, -8) + loc_1245_, 0);
											if rt_greater_than_u32(loc_1247_, 255) then
												loc_1240_ = buffer_read_i32(loc_1237_[1], loc_1241_, 24);
												if rt_equal_i32(loc_1248_, loc_1241_) then
													loc_1247_ = buffer_read_i32(loc_1237_[1], loc_1241_, 20);
													if rt_equal_i32(loc_1247_, 0) then
														loc_1247_ = buffer_read_i32(loc_1237_[1], loc_1241_, 16);
														if rt_equal_i32(loc_1247_, 0) then
															loc_1248_ = 1;
															loc_1245_ = 0;
														else
															loc_1245_ = loc_1248_;
															loc_1248_ = loc_1239_;
															loc_1239_ = loc_1241_;
															loc_1248_ = 0;
															loc_1241_ = loc_1239_;
															loc_1239_ = bit32_or(loc_1239_ + 16, 0);
														end
													else
														loc_1245_ = loc_1248_;
														loc_1248_ = loc_1239_;
														loc_1239_ = loc_1241_;
														loc_1248_ = 0;
														loc_1241_ = loc_1239_;
														loc_1239_ = bit32_or(loc_1239_ + 20, 0);
													end
													if not (rt_not_equal_i32(loc_1248_, 0)) then
														loc_1248_ = loc_1238_;
														loc_1239_, loc_1247_ = loc_1247_, loc_1239_;
														loc_1238_ = loc_1247_;
														loc_1247_ = loc_1248_;
														repeat
															rt_yield_budget = rt_yield_budget - 1
															if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
															loc_1248_ = loc_1245_;
															loc_1245_ = loc_1247_;
															loc_1247_ = loc_1238_;
															loc_1248_ = buffer_read_i32(loc_1237_[1], loc_1239_, 20);
															loc_1238_ = bit32_or(loc_1239_ + 20, 0);
															if rt_not_equal_i32(loc_1248_, 0) then
																loc_1245_ = loc_1239_;
																loc_1239_ = loc_1248_;
																loc_1248_ = loc_1244_;
																loc_1248_ = 1;
																loc_1244_ = 65535;
															else
																loc_1245_ = loc_1239_;
																loc_1239_ = loc_1238_;
																loc_1244_, loc_1248_ = loc_1248_, loc_1244_;
																loc_1239_ = buffer_read_i32(loc_1237_[1], loc_1245_, 16);
																loc_1238_ = bit32_or(loc_1245_ + 16, 0);
																if rt_not_equal_i32(loc_1239_, 0) then
																	loc_1248_ = 1;
																	loc_1244_ = 65535;
																else
																	loc_1244_ = loc_1248_;
																	loc_1248_ = 0;
																end
															end
														until loc_1248_ == 0
														rt_store_i32(loc_1237_, loc_1247_, 0, 0)
													end
												else
													loc_1245_ = loc_1238_;
													loc_1247_ = loc_1239_;
													loc_1247_ = buffer_read_i32(loc_1237_[1], loc_1241_, 8);
													rt_store_i32(loc_1237_, loc_1247_, 12, loc_1248_)
													rt_store_i32(loc_1237_, loc_1248_, 8, loc_1247_)
													loc_1245_ = loc_1248_;
												end
												if not (rt_equal_i32(loc_1240_, 0)) then
													loc_1238_ = buffer_read_i32(loc_1237_[1], loc_1241_, 28);
													loc_1239_ = rt_shift_left_i32(loc_1238_, 2);
													loc_1247_ = buffer_read_i32(loc_1237_[1], loc_1239_, 72268);
													if rt_not_equal_i32(loc_1241_, loc_1247_) then
														loc_1239_ = buffer_read_i32(loc_1237_[1], loc_1240_, 16);
														if rt_not_equal_i32(loc_1239_, loc_1241_) then
															rt_store_i32(loc_1237_, loc_1240_, 20, loc_1245_)
														else
															rt_store_i32(loc_1237_, loc_1240_, 16, loc_1245_)
														end
														if rt_equal_i32(loc_1245_, 0) then
															loc_1239_ = 1;
														else
															loc_1239_ = 0;
														end
													else
														rt_store_i32(loc_1237_, bit32_or(loc_1239_ + 72268, 0), 0, loc_1245_)
														if rt_not_equal_i32(loc_1245_, 0) then
															loc_1239_ = loc_1238_;
															loc_1239_ = 0;
														else
															loc_1239_ = loc_1238_;
															loc_1238_ = buffer_read_i32(loc_1237_[1], 0, 71968);
															rt_store_i32(loc_1237_, 0, 71968, rt_and_i32(loc_1238_, rt_rotate_left_i32(-2, loc_1239_)))
															loc_1239_ = 1;
														end
													end
													if not (rt_not_equal_i32(loc_1239_, 0)) then
														rt_store_i32(loc_1237_, loc_1245_, 24, loc_1240_)
														loc_1240_ = buffer_read_i32(loc_1237_[1], loc_1241_, 16);
														if not (rt_equal_i32(loc_1240_, 0)) then
															rt_store_i32(loc_1237_, loc_1245_, 16, loc_1240_)
															rt_store_i32(loc_1237_, loc_1240_, 24, loc_1245_)
														end
														loc_1241_ = buffer_read_i32(loc_1237_[1], loc_1241_, 20);
														if not (rt_equal_i32(loc_1241_, 0)) then
															rt_store_i32(loc_1237_, loc_1245_, 20, loc_1241_)
															rt_store_i32(loc_1237_, loc_1241_, 24, loc_1245_)
														end
													end
												end
											else
												loc_1240_ = loc_1238_;
												loc_1245_ = loc_1239_;
												loc_1245_ = buffer_read_i32(loc_1237_[1], loc_1241_, 8);
												if rt_not_equal_i32(loc_1248_, loc_1245_) then
													loc_1245_, loc_1247_ = loc_1247_, loc_1245_;
													loc_1247_, loc_1248_ = loc_1248_, loc_1247_;
													rt_store_i32(loc_1237_, loc_1247_, 8, loc_1248_)
													rt_store_i32(loc_1237_, loc_1248_, 12, loc_1247_)
												else
													loc_1245_, loc_1247_ = loc_1247_, loc_1245_;
													loc_1248_ = buffer_read_i32(loc_1237_[1], 0, 71964);
													rt_store_i32(loc_1237_, 0, 71964, rt_and_i32(loc_1248_, rt_rotate_left_i32(-2, rt_shift_right_u32(loc_1245_, 3))))
												end
											end
											rt_store_i32(loc_1237_, bit32_or(loc_1242_ + loc_1243_, 0), 0, loc_1243_)
											rt_store_i32(loc_1237_, loc_1242_, 4, rt_or_i32(loc_1243_, 1))
											if rt_not_equal_i32(loc_1242_, loc_1246_) then
												loc_1246_ = 0;
											else
												rt_store_i32(loc_1237_, 0, 71972, loc_1243_)
												loc_1246_ = 4;
											end
										else
											loc_1243_ = loc_1246_;
											loc_1246_ = loc_1239_;
											loc_1248_ = loc_1241_;
											loc_1241_ = loc_1238_;
											rt_store_i32(loc_1237_, 0, 71984, loc_1242_)
											loc_1248_ = buffer_read_i32(loc_1237_[1], 0, 71972);
											loc_1243_ = bit32_or(loc_1248_ + loc_1245_, 0);
											rt_store_i32(loc_1237_, 0, 71972, loc_1243_)
											rt_store_i32(loc_1237_, loc_1242_, 4, rt_or_i32(loc_1243_, 1))
											rt_store_i32(loc_1237_, bit32_or(loc_1242_ + loc_1243_, 0), 0, loc_1243_)
											loc_1246_ = 3;
										end
									else
										loc_1247_ = loc_1246_;
										loc_1246_ = loc_1241_;
										loc_1248_ = loc_1245_;
										loc_1245_ = loc_1243_;
										loc_1243_ = loc_1240_;
										rt_store_i32(loc_1237_, 0, 71988, loc_1242_)
										loc_1248_ = buffer_read_i32(loc_1237_[1], 0, 71976);
										loc_1243_ = bit32_or(loc_1248_ + loc_1245_, 0);
										rt_store_i32(loc_1237_, 0, 71976, loc_1243_)
										rt_store_i32(loc_1237_, loc_1242_, 4, rt_or_i32(loc_1243_, 1))
										loc_1248_ = buffer_read_i32(loc_1237_[1], 0, 71984);
										if rt_not_equal_i32(loc_1242_, loc_1248_) then
											loc_1246_ = 1;
										else
											rt_store_i32(loc_1237_, 0, 71972, 0)
											rt_store_i32(loc_1237_, 0, 71984, 0)
											loc_1246_ = 2;
										end
									end
								end
								if (loc_1246_) >= 0 and (loc_1246_) < 4 then
									if (loc_1246_) < 2 then
										if (loc_1246_) < 1 then
											if rt_greater_than_u32(loc_1243_, 255) then
												loc_1239_ = loc_1243_;
												loc_1243_ = loc_1242_;
												loc_1242_ = loc_1244_;
												loc_1240_ = 31;
												if not (rt_greater_than_u32(loc_1239_, 16777215)) then
													loc_1245_ = loc_1239_;
													loc_1246_ = loc_1240_;
													loc_1239_ = loc_1245_;
													loc_1246_ = rt_leading_zeroes_i32(rt_shift_right_u32(loc_1245_, 8));
													loc_1240_ = bit32_or(bit32_or(rt_and_i32(rt_shift_right_u32(loc_1245_, bit32_or(38 - loc_1246_, 0)), 1) - rt_shift_left_i32(loc_1246_, 1), 0) + 62, 0);
												end
												rt_store_i32(loc_1237_, loc_1243_, 28, loc_1240_)
												rt_store_i64(loc_1237_, loc_1243_, 16, into_bits_i64(0, 0))
												loc_1241_ = buffer_read_i32(loc_1237_[1], 0, 71968);
												loc_1244_ = rt_shift_left_i32(1, loc_1240_);
												loc_1238_ = bit32_or(rt_shift_left_i32(loc_1240_, 2) + 72268, 0);
												if rt_not_equal_i32(rt_and_i32(loc_1241_, loc_1244_), 0) then
													loc_1245_ = 0;
													loc_1246_ = bit32_or(25 - rt_shift_right_u32(loc_1240_, 1), 0);
													if rt_equal_i32(loc_1240_, 31) then
														loc_1240_ = loc_1239_;
													else
														loc_1240_ = loc_1239_;
														loc_1245_ = loc_1246_;
													end
													loc_1238_ = buffer_read_i32(loc_1237_[1], loc_1238_, 0);
													loc_1239_ = rt_shift_left_i32(loc_1239_, loc_1245_);
													repeat
														rt_yield_budget = rt_yield_budget - 1
														if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
														loc_1245_ = loc_1242_;
														loc_1242_ = loc_1241_;
														loc_1245_ = buffer_read_i32(loc_1237_[1], loc_1238_, 4);
														if rt_equal_i32(rt_and_i32(loc_1245_, -8), loc_1240_) then
															loc_1241_ = loc_1238_;
															loc_1245_ = 0;
															loc_1242_ = 1;
														else
															loc_1241_ = loc_1238_;
															loc_1245_ = loc_1244_;
															loc_1244_ = loc_1238_;
															loc_1244_ = bit32_or(loc_1241_ + rt_and_i32(rt_shift_right_u32(loc_1239_, 29), 4), 0);
															loc_1238_ = buffer_read_i32(loc_1237_[1], loc_1244_, 16);
															loc_1239_ = rt_shift_left_i32(loc_1239_, 1);
															if rt_not_equal_i32(loc_1238_, 0) then
																loc_1245_ = 1;
																loc_1242_ = 65535;
															else
																loc_1245_ = 0;
																loc_1242_ = 0;
															end
														end
													until loc_1245_ == 0
													if rt_not_equal_i32(loc_1242_, 0) then
														loc_1240_ = buffer_read_i32(loc_1237_[1], loc_1241_, 8);
														rt_store_i32(loc_1237_, loc_1240_, 12, loc_1243_)
														rt_store_i32(loc_1237_, loc_1241_, 8, loc_1243_)
														loc_1238_ = 1;
														loc_1242_ = 24;
														loc_1239_ = 8;
														loc_1244_ = 0;
													else
														loc_1240_ = loc_1241_;
														rt_store_i32(loc_1237_, bit32_or(loc_1244_ + 16, 0), 0, loc_1243_)
														loc_1238_ = 0;
														loc_1242_ = 8;
														loc_1239_ = 24;
														loc_1241_ = loc_1240_;
													end
												else
													loc_1245_ = loc_1242_;
													loc_1242_ = loc_1239_;
													loc_1246_ = loc_1238_;
													rt_store_i32(loc_1237_, loc_1246_, 0, loc_1243_)
													rt_store_i32(loc_1237_, 0, 71968, rt_or_i32(loc_1241_, loc_1244_))
													loc_1238_ = 0;
													loc_1242_ = 8;
													loc_1239_ = 24;
													loc_1240_ = loc_1246_;
												end
												if not (rt_not_equal_i32(loc_1238_, 0)) then
													loc_1241_, loc_1243_ = loc_1243_, loc_1241_;
													loc_1243_ = loc_1241_;
													loc_1244_ = loc_1241_;
												end
												rt_store_i32(loc_1237_, bit32_or(loc_1243_ + loc_1239_, 0), 0, loc_1240_)
												rt_store_i32(loc_1237_, loc_1243_, 12, loc_1241_)
												rt_store_i32(loc_1237_, bit32_or(loc_1243_ + loc_1242_, 0), 0, loc_1244_)
												loc_1244_ = buffer_read_i32(loc_1237_[1], 0, 71996);
												loc_1243_ = 0;
												loc_1244_ = bit32_or(loc_1244_ + -1, 0);
												loc_1242_ = -1;
												if not (rt_not_equal_i32(loc_1244_, 0)) then
													loc_1244_ = loc_1242_;
												end
												rt_store_i32(loc_1237_, loc_1243_, 71996, loc_1244_)
												loc_1238_ = 0;
											else
												loc_1239_ = loc_1243_;
												loc_1243_ = loc_1242_;
												loc_1246_ = loc_1244_;
												loc_1246_ = buffer_read_i32(loc_1237_[1], 0, 71964);
												loc_1245_ = rt_shift_left_i32(1, rt_shift_right_u32(loc_1239_, 3));
												loc_1244_ = bit32_or(rt_and_i32(loc_1239_, -8) + 72004, 0);
												if rt_not_equal_i32(rt_and_i32(loc_1246_, loc_1245_), 0) then
													loc_1243_, loc_1246_ = loc_1246_, loc_1243_;
													loc_1245_ = buffer_read_i32(loc_1237_[1], loc_1244_, 8);
												else
													loc_1243_, loc_1246_ = loc_1246_, loc_1243_;
													rt_store_i32(loc_1237_, 0, 71964, rt_or_i32(loc_1243_, loc_1245_))
													loc_1245_ = loc_1244_;
												end
												rt_store_i32(loc_1237_, loc_1245_, 12, loc_1246_)
												rt_store_i32(loc_1237_, loc_1244_, 8, loc_1246_)
												rt_store_i32(loc_1237_, loc_1246_, 12, loc_1244_)
												rt_store_i32(loc_1237_, loc_1246_, 8, loc_1245_)
												loc_1238_ = 1;
											end
										else
											loc_1238_ = 0;
										end
									elseif (loc_1246_) > 2 then
										loc_1238_ = 1;
									else
										loc_1238_ = 1;
									end
								else
									loc_1238_ = 1;
								end
							end
						end
					elseif (loc_1248_) > 1 then
						loc_1238_, loc_1243_ = loc_1243_, loc_1238_;
						loc_1243_, loc_1241_ = loc_1241_, loc_1243_;
						loc_1241_, loc_1239_ = loc_1239_, loc_1241_;
						loc_1239_, loc_1242_ = loc_1242_, loc_1239_;
						loc_1242_, loc_1240_ = loc_1240_, loc_1242_;
						loc_1238_ = 0;
					else
						loc_1238_, loc_1243_ = loc_1243_, loc_1238_;
						loc_1243_, loc_1241_ = loc_1241_, loc_1243_;
						loc_1241_, loc_1239_ = loc_1239_, loc_1241_;
						loc_1239_, loc_1242_ = loc_1242_, loc_1239_;
						loc_1242_, loc_1240_ = loc_1240_, loc_1242_;
						loc_1238_ = 0;
					end
				else
					loc_1238_ = 1;
				end
			end
			if rt_not_equal_i32(loc_1238_, 0) then
			end
			return loc_1236_
		end), "i32->")
	end)(module_locals[3]);
	module_locals[111][1] = (function(loc_1249_, loc_1250_)
		return rt_function_type((function(loc_1251_, loc_1252_, loc_1253_)
			local loc_1254_, loc_1255_, loc_1256_, loc_1257_, loc_1258_, loc_1259_, loc_1260_
			if rt_not_equal_i32(loc_1251_, 0) then
				loc_1254_ = loc_1252_;
				loc_1256_ = loc_1250_;
				loc_1257_ = loc_1249_;
				loc_1259_ = loc_1253_;
				loc_1260_ = loc_1251_;
				loc_1255_ = rt_multiply_i64(rt_widen_i32(loc_1260_), rt_widen_i32(loc_1254_));
				loc_1258_ = rt_narrow_i64(loc_1255_);
				if not (rt_less_than_u32(rt_or_i32(loc_1254_, loc_1260_), 65536)) then
					loc_1254_ = loc_1258_;
					loc_1258_ = -1;
					if rt_not_equal_i32(rt_narrow_i64(rt_shift_right_u64(loc_1255_, into_bits_i64(32, 0))), 0) then
						loc_1255_ = loc_1254_;
					else
						loc_1255_ = loc_1254_;
						loc_1258_ = loc_1255_;
					end
				end
			else
				loc_1256_ = loc_1250_;
				loc_1257_ = loc_1249_;
				loc_1258_ = loc_1252_;
				loc_1259_ = loc_1253_;
				loc_1260_ = loc_1251_;
				loc_1258_ = 0;
			end
			loc_1255_ = loc_1257_[1](loc_1258_, loc_1259_)
			if not (rt_equal_i32(loc_1255_, 0)) then
				loc_1259_ = rt_load_i32_from_u8(loc_1256_, bit32_or(loc_1255_ + -4, 0), 0);
				if not (rt_equal_i32(rt_and_i32(loc_1259_, 3), 0)) then
					if not (rt_equal_i32(loc_1258_, 0)) then
						rt_memory_fill(loc_1256_, loc_1255_, 0, loc_1258_)
					end
				end
			end
			return loc_1255_, loc_1254_
		end), "i32,i32->i32")
	end)(module_locals[107], module_locals[3]);
	module_locals[116] = rt_table_new({ }, 5, 5);
	rt_table_set(module_locals[116], 0, module_locals[65][1]);
	rt_table_set(module_locals[116], 1, module_locals[67][1]);
	rt_table_set(module_locals[116], 2, module_locals[70][1]);
	rt_table_set(module_locals[116], 3, module_locals[71][1]);
	rt_table_set(module_locals[116], 4, module_locals[84][1]);
	rt_table_copy(module_locals[112], (function(loc_1261_)
		local loc_1262_
		loc_1262_ = loc_1261_;
		return 1, loc_1262_
	end)(), module_locals[116], 0, 5)
	module_locals[117] = rt_memory_new({ [0] = "-+   0X0x\x00-0X+0X 0X-0x+0x 0x\x00greeting.txt\x00r\x00q\x00nan\x00inf\x00demo: bye\x00space\x00rwa\x00NAN\x00INF\x00.\x00(null)\x00demo: argc=%d argv[0]=%s\n\x00demo: greeting = %s\n\x00demo: %d frames, %.1f s\n\x00Support for formatting long double values is currently disabled.\nTo enable it, add -lc-printscan-long-double to the link command.\n\x00demo: sum 1/i^2 = %.9f (pi^2/6 = %.9f)\n\x00\x00\x00(no greeting.txt)\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00\x04\x00\x00\x00\x04\x00\x00\x00\x06\x00\x00\x00\x83\xf9\xa2\x00DNn\x00\xfc)\x15\x00\xd1W\'\x00\xdd4\xf5\x00b\xdb\xc0\x00<\x99\x95\x00A\x90C\x00cQ\xfe\x00\xbb\xde\xab\x00\xb7a\xc5\x00:n$\x00\xd2MB\x00I\x06\xe0\x00\t\xea.\x00\x1c\x92\xd1\x00\xeb\x1d\xfe\x00)\xb1\x1c\x00\xe8>\xa7\x00\xf55\x82\x00D\xbb.\x00\x9c\xe9\x84\x00\xb4&p\x00A~_\x00\xd6\x919\x00S\x839\x00\x9c\xf49\x00\x8b_\x84\x00(\xf9\xbd\x00\xf8\x1f;\x00\xde\xff\x97\x00\x0f\x98\x05\x00\x11/\xef\x00\nZ\x8b\x00m\x1fm\x00\xcf~6\x00\t\xcb\'\x00FO\xb7\x00\x9ef?\x00-\xea_\x00\xba\'u\x00\xe5\xeb\xc7\x00={\xf1\x00\xf79\x07\x00\x92R\x8a\x00\xfbk\xea\x00\x1f\xb1_\x00\x08]\x8d\x000\x03V\x00{\xfcF\x00\xf0\xabk\x00 \xbc\xcf\x006\xf4\x9a\x00\xe3\xa9\x1d\x00^a\x91\x00\x08\x1b\xe6\x00\x85\x99e\x00\xa0\x14_\x00\x8d@h\x00\x80\xd8\xff\x00\'sM\x00\x06\x061\x00\xcaV\x15\x00\xc9\xa8s\x00{\xe2`\x00k\x8c\xc0\x00\x19\xc4G\x00\xcdg\xc3\x00\t\xe8\xdc\x00Y\x83*\x00\x8bv\xc4\x00\xa6\x1c\x96\x00D\xaf\xdd\x00\x19W\xd1\x00\xa5>\x05\x00\x05\x07\xff\x003~?\x00\xc22\xe8\x00\x98O\xde\x00\xbb}2\x00&=\xc3\x00\x1ek\xef\x00\x9f\xf8^\x005\x1f:\x00\x7f\xf2\xca\x00\xf1\x87\x1d\x00|\x90!\x00j$|\x00\xd5n\xfa\x000-w\x00\x15;C\x00\xb5\x14\xc6\x00\xc3\x19\x9d\x00\xad\xc4\xc2\x00,MA\x00\x0c\x00]\x00\x86}F\x00\xe3q-\x00\x9b\xc6\x9a\x003b\x00\x00\xb4\xd2|\x00\xb4\xa7\x97\x007U\xd5\x00\xd7>\xf6\x00\xa3\x10\x18\x00Mv\xfc\x00d\x9d*\x00p\xd7\xab\x00c|\xf8\x00z\xb0W\x00\x17\x15\xe7\x00\xc0IV\x00;\xd6\xd9\x00\xa7\x848\x00$#\xcb\x00\xd6\x8aw\x00ZT#\x00\x00\x1f\xb9\x00\xf1\n\x1b\x00\x19\xce\xdf\x00\x9f1\xff\x00f\x1ej\x00\x99Wa\x00\xac\xfbG\x00~\x7f\xd8\x00\"e\xb7\x002\xe8\x89\x00\xe6\xbf`\x00\xef\xc4\xcd\x00l6\t\x00]?\xd4\x00\x16\xde\xd7\x00X;\xde\x00\xde\x9b\x92\x00\xd2\"(\x00(\x86\xe8\x00\xe2XM\x00\xc6\xca2\x00\x08\xe3\x16\x00\xe0}\xcb\x00\x17\xc0P\x00\xf3\x1d\xa7\x00\x18\xe0[\x00.\x134\x00\x83\x12b\x00\x83H\x01\x00\xf5\x8e[\x00\xad\xb0\x7f\x00\x1e\xe9\xf2\x00HJC\x00\x10g\xd3\x00\xaa\xdd\xd8\x00\xae_B\x00ja\xce\x00\n(\xa4\x00\xd3\x99\xb4\x00\x06\xa6\xf2\x00\\w\x7f\x00\xa3\xc2\x83\x00a<\x88\x00\x8asx\x00\xaf\x8cZ\x00o\xd7\xbd\x00-\xa6c\x00\xf4\xbf\xcb\x00\x8d\x81\xef\x00&\xc1g\x00U\xcaE\x00\xca\xd96\x00(\xa8\xd2\x00\xc2a\x8d\x00\x12\xc9w\x00\x04&\x14\x00\x12F\x9b\x00\xc4Y\xc4\x00\xc8\xc5D\x00M\xb2\x91\x00\x00\x17\xf3\x00\xd4C\xad\x00)I\xe5\x00\xfd\xd5\x10\x00\x00\xbe\xfc\x00\x1e\x94\xcc\x00p\xce\xee\x00\x13>\xf5\x00\xec\xf1\x80\x00\xb3\xe7\xc3\x00\xc7\xf8(\x00\x93\x05\x94\x00\xc1q>\x00.\t\xb3\x00\x0bE\xf3\x00\x88\x12\x9c\x00\xab {\x00.\xb5\x9f\x00G\x92\xc2\x00{2/\x00\x0cUm\x00r\xa7\x90\x00k\xe7\x1f\x001\xcb\x96\x00y\x16J\x00Ay\xe2\x00\xf4\xdf\x89\x00\xe8\x94\x97\x00\xe2\xe6\x84\x00\x991\x97\x00\x88\xedk\x00__6\x00\xbb\xfd\x0e\x00H\x9a\xb4\x00g\xa4l\x00qrB\x00\x8d]2\x00\x9f\x15\xb8\x00\xbc\xe5\t\x00\x8d1%\x00\xf7t9\x000\x05\x1c\x00\r\x0c\x01\x00K\x08h\x00,\xeeX\x00G\xaa\x90\x00t\xe7\x02\x00\xbd\xd6$\x00\xf7}\xa6\x00nHr\x00\x9f\x16\xef\x00\x8e\x94\xa6\x00\xb4\x91\xf6\x00\xd1SQ\x00\xcf\n\xf2\x00 \x983\x00\xf5K~\x00\xb2ch\x00\xdd>_\x00@]\x03\x00\x85\x89\x7f\x00UR)\x007d\xc0\x00m\xd8\x10\x002H2\x00[Lu\x00Nq\xd4\x00ETn\x00\x0b\t\xc1\x00*\xf5i\x00\x14f\xd5\x00\'\x07\x9d\x00]\x04P\x00\xb4;\xdb\x00\xeav\xc5\x00\x87\xf9\x17\x00Ik}\x00\x1d\'\xba\x00\x96i)\x00\xc6\xcc\xac\x00\xad\x14T\x00\x90\xe2j\x00\x88\xd9\x89\x00,rP\x00\x04\xa4\xbe\x00w\x07\x94\x00\xf30p\x00\x00\xfc\'\x00\xeaq\xa8\x00f\xc2I\x00d\xe0=\x00\x97\xdd\x83\x00\xa3?\x97\x00C\x94\xfd\x00\r\x86\x8c\x001A\xde\x00\x929\x9d\x00\xddp\x8c\x00\x17\xb7\xe7\x00\x08\xdf;\x00\x157+\x00\\\x80\xa0\x00Z\x80\x93\x00\x10\x11\x92\x00\x0f\xe8\xd8\x00l\x80\xaf\x00\xdb\xffK\x008\x90\x0f\x00Y\x18v\x00b\xa5\x15\x00a\xcb\xbb\x00\xc7\x89\xb9\x00\x10@\xbd\x00\xd2\xf2\x04\x00Iu\'\x00\xeb\xb6\xf6\x00\xdb\"\xbb\x00\n\x14\xaa\x00\x89&/\x00d\x83v\x00\t;3\x00\x0e\x94\x1a\x00Q:\xaa\x00\x1d\xa3\xc2\x00\xaf\xed\xae\x00\\&\x12\x00m\xc2M\x00-z\x9c\x00\xc0V\x97\x00\x03?\x83\x00\t\xf0\xf6\x00+@\x8c\x00m1\x99\x009\xb4\x07\x00\x0c \x15\x00\xd8\xc3[\x00\xf5\x92\xc4\x00\xc6\xadK\x00N\xca\xa5\x00\xa77\xcd\x00\xe6\xa96\x00\xab\x92\x94\x00\xddBh\x00\x19c\xde\x00v\x8c\xef\x00h\x8bR\x00\xfc\xdb7\x00\xae\xa1\xab\x00\xdf\x151\x00\x00\xae\xa1\x00\x0c\xfb\xda\x00dMf\x00\xed\x05\xb7\x00)e0\x00WV\xbf\x00G\xff:\x00j\xf9\xb9\x00u\xbe\xf3\x00(\x93\xdf\x00\xab\x800\x00f\x8c\xf6\x00\x04\xcb\x15\x00\xfa\"\x06\x00\xd9\xe4\x1d\x00=\xb3\xa4\x00W\x1b\x8f\x006\xcd\t\x00NB\xe9\x00\x13\xbe\xa4\x003#\xb5\x00\xf0\xaa\x1a\x00Oe\xa8\x00\xd2\xc1\xa5\x00\x0b?\x0f\x00[x\xcd\x00#\xf9v\x00{\x8b\x04\x00\x89\x17r\x00\xc6\xa6S\x00on\xe2\x00\xef\xeb\x00\x00\x9bJX\x00\xc4\xda\xb7\x00\xaaf\xba\x00v\xcf\xcf\x00\xd1\x02\x1d\x00\xb1\xf1-\x00\x8c\x99\xc1\x00\xc3\xadw\x00\x86H\xda\x00\xf7]\xa0\x00\xc6\x80\xf4\x00\xac\xf0/\x00\xdd\xec\x9a\x00?\\\xbc\x00\xd0\xdem\x00\x90\xc7\x1f\x00*\xdb\xb6\x00\xa3%:\x00\x00\xaf\x9a\x00\xadS\x93\x00\xb6W\x04\x00)-\xb4\x00K\x80~\x00\xda\x07\xa7\x00v\xaa\x0e\x00{Y\xa1\x00\x16\x12*\x00\xdc\xb7-\x00\xfa\xe5\xfd\x00\x89\xdb\xfe\x00\x89\xbe\xfd\x00\xe4vl\x00\x06\xa9\xfc\x00>\x80p\x00\x85n\x15\x00\xfd\x87\xff\x00(>\x07\x00ag3\x00*\x18\x86\x00M\xbd\xea\x00\xb3\xe7\xaf\x00\x8fmn\x00\x95g9\x001\xbf[\x00\x84\xd7H\x000\xdf\x16\x00\xc7-C\x00%a5\x00\xc9p\xce\x000\xcb\xb8\x00\xbfl\xfd\x00\xa4\x00\xa2\x00\x05l\xe4\x00Z\xdd\xa0\x00!oG\x00b\x12\xd2\x00\xb9\\\x84\x00paI\x00kV\xe0\x00\x99R\x01\x00PU7\x00\x1e\xd5\xb7\x003\xf1\xc4\x00\x13n_\x00]0\xe4\x00\x85.\xa9\x00\x1d\xb2\xc3\x00\xa126\x00\x08\xb7\xa4\x00\xea\xb1\xd4\x00\x16\xf7!\x00\x8fi\xe4\x00\'\xffw\x00\x0c\x03\x80\x00\x8d@-\x00O\xcd\xa0\x00 \xa5\x99\x00\xb3\xa2\xd3\x00/]\n\x00\xb4\xf9B\x00\x11\xda\xcb\x00}\xbe\xd0\x00\x9b\xdb\xc1\x00\xab\x17\xbd\x00\xca\xa2\x81\x00\x08j\\\x00.U\x17\x00\'\x00U\x00\x7f\x14\xf0\x00\xe1\x07\x86\x00\x14\x0bd\x00\x96A\x8d\x00\x87\xbe\xde\x00\xda\xfd*\x00k%\xb6\x00{\x894\x00\x05\xf3\xfe\x00\xb9\xbf\x9e\x00hjO\x00J*\xa8\x00O\xc4Z\x00-\xf8\xbc\x00\xd7Z\x98\x00\xf4\xc7\x95\x00\rM\x8d\x00 :\xa6\x00\xa4W_\x00\x14?\xb1\x00\x808\x95\x00\xcc \x01\x00q\xdd\x86\x00\xc9\xde\xb6\x00\xbf`\xf5\x00Me\x11\x00\x01\x07k\x00\x8c\xb0\xac\x00\xb2\xc0\xd0\x00QUH\x00\x1e\xfb\x0e\x00\x95r\xc3\x00\xa3\x06;\x00\xc0@5\x00\x06\xdc{\x00\xe0E\xcc\x00N)\xfa\x00\xd6\xca\xc8\x00\xe8\xf3A\x00|d\xde\x00\x9bd\xd8\x00\xd9\xbe1\x00\xa4\x97\xc3\x00wX\xd4\x00i\xe3\xc5\x00\xf0\xda\x13\x00\xba:<\x00F\x18F\x00Uu_\x00\xd2\xbd\xf5\x00n\x92\xc6\x00\xac.]\x00\x0eD\xed\x00\x1c>B\x00a\xc4\x87\x00)\xfd\xe9\x00\xe7\xd6\xf3\x00\"|\xca\x00o\x915\x00\x08\xe0\xc5\x00\xff\xd7\x8d\x00nj\xe2\x00\xb0\xfd\xc6\x00\x93\x08\xc1\x00|]t\x00k\xad\xb2\x00\xcdn\x9d\x00>r{\x00\xc6\x11j\x00\xf7\xcf\xa9\x00)s\xdf\x00\xb5\xc9\xba\x00\xb7\x00Q\x00\xe2\xb2\r\x00t\xba$\x00\xe5}`\x00t\xd8\x8a\x00\r\x15,\x00\x81\x18\x0c\x00~f\x94\x00\x01)\x16\x00\x9fzv\x00\xfd\xfd\xbe\x00VE\xef\x00\xd9~6\x00\xec\xd9\x13\x00\x8b\xba\xb9\x00\xc4\x97\xfc\x001\xa8\'\x00\xf1n\xc3\x00\x94\xc56\x00\xd8\xa8V\x00\xb4\xa8\xb5\x00\xcf\xcc\x0e\x00\x12\x89-\x00oW4\x00,V\x89\x00\x99\xce\xe3\x00\xd6 \xb9\x00k^\xaa\x00>*\x9c\x00\x11_\xcc\x00\xfd\x0bJ\x00\xe1\xf4\xfb\x00\x8e;m\x00\xe2\x86,\x00\xe9\xd4\x84\x00\xfc\xb4\xa9\x00\xef\xee\xd1\x00.5\xc9\x00/9a\x008!D\x00\x1b\xd9\xc8\x00\x81\xfc\n\x00\xfbJj\x00/\x1c\xd8\x00S\xb4\x84\x00N\x99\x8c\x00T\"\xcc\x00*U\xdc\x00\xc0\xc6\xd6\x00\x0b\x19\x96\x00\x1ap\xb8\x00i\x95d\x00&Z`\x00?R\xee\x00\x7f\x11\x0f\x00\xf4\xb5\x11\x00\xfc\xcb\xf5\x004\xbc-\x004\xbc\xee\x00\xe8]\xcc\x00\xdd^`\x00g\x8e\x9b\x00\x923\xef\x00\xc9\x17\xb8\x00aX\x9b\x00\xe1W\xbc\x00Q\x83\xc6\x00\xd8>\x10\x00\xddqH\x00-\x1c\xdd\x00\xaf\x18\xa1\x00!,F\x00Y\xf3\xd7\x00\xd9z\x98\x00\x9eT\xc0\x00O\x86\xfa\x00V\x06\xfc\x00\xe5y\xae\x00\x89\"6\x008\xad\"\x00g\x93\xdc\x00U\xe8\xaa\x00\x82&8\x00\xca\xe7\x9b\x00Q\r\xa4\x00\x993\xb1\x00\xa9\xd7\x0e\x00i\x05H\x00e\xb2\xf0\x00\x7f\x88\xa7\x00\x88L\x97\x00\xf9\xd16\x00!\x92\xb3\x00{\x82J\x00\x98\xcf!\x00@\x9f\xdc\x00\xdcGU\x00\xe1t:\x00g\xebB\x00\xfe\x9d\xdf\x00^\xd4_\x00{g\xa4\x00\xba\xacz\x00U\xf6\xa2\x00+\x88#\x00A\xbaU\x00Yn\x08\x00!*\x86\x009G\x83\x00\x89\xe3\xe6\x00\xe5\x9e\xd4\x00I\xfb@\x00\xffV\xe9\x00\x1c\x0f\xca\x00\xc5Y\x8a\x00\x94\xfa+\x00\xd3\xc1\xc5\x00\x0f\xc5\xcf\x00\xdbZ\xae\x00G\xc5\x86\x00\x85Cb\x00!\x86;\x00,y\x94\x00\x10a\x87\x00*L{\x00\x80,\x1a\x00C\xbf\x12\x00\x88&\x90\x00x<\x89\x00\xa8\xc4\xe4\x00\xe5\xdb{\x00\xc4:\xc2\x00&\xf4\xea\x00\xf7g\x8a\x00\r\x92\xbf\x00e\xa3+\x00=\x93\xb1\x00\xbd|\x0b\x00\xa4Q\xdc\x00\'\xddc\x00i\xe1\xdd\x00\x9a\x94\x19\x00\xa8)\x95\x00h\xce(\x00\t\xed\xb4\x00D\x9f \x00N\x98\xca\x00p\x82c\x00~|#\x00\x0f\xb92\x00\xa7\xf5\x8e\x00\x14V\xe7\x00!\xf1\x08\x00\xb5\x9d*\x00o~M\x00\xa5\x19Q\x00\xb5\xf9\xab\x00\x82\xdf\xd6\x00\x96\xdda\x00\x166\x02\x00\xc4:\x9f\x00\x83\xa2\xa1\x00r\xedm\x009\x8dz\x00\x82\xb8\xa9\x00k2\\\x00F\'[\x00\x004\xed\x00\xd2\x00w\x00\xfc\xf4U\x00\x01YM\x00\xe0q\x80\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00@\xfb!\xf9?\x00\x00\x00\x00-Dt>\x00\x00\x00\x80\x98F\xf8<\x00\x00\x00`Q\xccx;\x00\x00\x00\x80\x83\x1b\xf09\x00\x00\x00@ %z8\x00\x00\x00\x80\"\x82\xe36\x00\x00\x00\x00\x1d\xf3i5Success\x00Illegal byte sequence\x00Domain error\x00Result not representable\x00Not a tty\x00Permission denied\x00Operation not permitted\x00No such file or directory\x00No such process\x00File exists\x00Value too large for data type\x00No space left on device\x00Out of memory\x00Resource busy\x00Interrupted system call\x00Resource temporarily unavailable\x00Invalid seek\x00Cross-device link\x00Read-only file system\x00Directory not empty\x00Connection reset by peer\x00Operation timed out\x00Connection refused\x00Host is unreachable\x00Address in use\x00Broken pipe\x00I/O error\x00No such device or address\x00No such device\x00Not a directory\x00Is a directory\x00Text file busy\x00Exec format error\x00Invalid argument\x00Argument list too long\x00Symbolic link loop\x00Filename too long\x00Too many open files in system\x00No file descriptors available\x00Bad file descriptor\x00No child process\x00Bad address\x00File too large\x00Too many links\x00No locks available\x00Resource deadlock would occur\x00State not recoverable\x00Previous owner died\x00Operation canceled\x00Function not implemented\x00No message of desired type\x00Identifier removed\x00Link has been severed\x00Protocol error\x00Bad message\x00Not a socket\x00Destination address required\x00Message too large\x00Protocol wrong type for socket\x00Protocol not available\x00Protocol not supported\x00Not supported\x00Address family not supported by protocol\x00Address not available\x00Network is down\x00Network unreachable\x00Connection reset by network\x00Connection aborted\x00No buffer space available\x00Socket is connected\x00Socket not connected\x00Operation already in progress\x00Operation in progress\x00Stale file handle\x00Quota exceeded\x00Multihop attempted\x00Capabilities insufficient\x00\x00\x00u\x02N\x00\xd6\x01\xe2\x04\xb9\x04\x18\x01\x8e\x05\xed\x02\x16\x04\xf2\x00\x97\x03\x01\x038\x05\xaf\x01\x82\x01O\x03/\x04\x1e\x00\xd4\x05\xa2\x00\x12\x03\x1e\x03\xc2\x01\xde\x03\x08\x00\xac\x05\x00\x01d\x02\xf1\x01e\x054\x02\x8c\x02\xcf\x02-\x03L\x04\xe3\x05\x9f\x02\xf8\x04\x1c\x05\x08\x05\xb1\x02K\x05\x15\x02x\x00R\x02<\x03\xf1\x03\xe4\x00\xc3\x03}\x04\xcc\x00\xaa\x03y\x05$\x02n\x01m\x03\"\x04\xab\x04D\x00\xfb\x01\xae\x00\x83\x03`\x00\xe5\x01\x07\x04\x94\x04^\x04+\x00X\x019\x01\x92\x00\xc2\x05\x9b\x01C\x02F\x01\xf6\x05\x00\x00\x00\x00\x00\x00\x19\x00\x0b\x00\x19\x19\x19\x00\x00\x00\x00\x05\x00\x00\x00\x00\x00\x00\t\x00\x00\x00\x00\x0b\x00\x00\x00\x00\x00\x00\x00\x00\x19\x00\n\n\x19\x19\x19\x03\n\x07\x00\x01\x1b\t\x0b\x18\x00\x00\t\x06\x0b\x00\x00\x0b\x00\x06\x19\x00\x00\x00\x19\x19\x19\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x0e\x00\x00\x00\x00\x00\x00\x00\x00\x19\x00\x0b\r\x19\x19\x19\x00\r\x00\x00\x02\x00\t\x0e\x00\x00\x00\t\x00\x0e\x00\x00\x0e\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x0c\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x13\x00\x00\x00\x00\x13\x00\x00\x00\x00\t\x0c\x00\x00\x00\x00\x00\x0c\x00\x00\x0c\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x10\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x0f\x00\x00\x00\x04\x0f\x00\x00\x00\x00\t\x10\x00\x00\x00\x00\x00\x10\x00\x00\x10\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x12\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x11\x00\x00\x00\x00\x11\x00\x00\x00\x00\t\x12\x00\x00\x00\x00\x00\x12\x00\x00\x12\x00\x00\x1a\x00\x00\x00\x1a\x1a\x1a\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x1a\x00\x00\x00\x1a\x1a\x1a\x00\x00\x00\x00\x00\x00\t\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x14\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x17\x00\x00\x00\x00\x17\x00\x00\x00\x00\t\x14\x00\x00\x00\x00\x00\x14\x00\x00\x14\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x16\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x15\x00\x00\x00\x00\x15\x00\x00\x00\x00\t\x16\x00\x00\x00\x00\x00\x16\x00\x00\x16\x00\x000123456789ABCDEF", }, 5440, 5440);
	rt_memory_copy(module_locals[3], (function(loc_1263_)
		local loc_1264_
		loc_1264_ = loc_1263_;
		return 1024, loc_1264_
	end)(), module_locals[117], 0, 5440)
	module_locals[118] = rt_memory_new({ [0] = "\x00\x00\x02\x00\x00\x00\x00\x00\x05\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x04\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x05\x00\x00\x00\x01\x00\x00\x00\xf8\x14\x01\x00\x00\x04\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\n\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00H\x19\x00\x00\x00\x00\x00\x00\x05\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x04\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x01\x00\x00\x00\x1c\x19\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\xff\xff\xff\xff\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xc0\x19\x00\x00", }, 244, 244);
	rt_memory_copy(module_locals[3], (function(loc_1265_)
		local loc_1266_
		loc_1266_ = loc_1265_;
		return 6464, loc_1266_
	end)(), module_locals[118], 0, 244)
	module_locals[114][1] = (function(loc_1267_)
		local loc_1268_
		loc_1268_ = loc_1267_;
		return 138000, loc_1268_
	end)();
	module_locals[115][1] = (function(loc_1269_)
		local loc_1270_
		loc_1270_ = loc_1269_;
		return 0, loc_1270_
	end)();
	rt_table_drop(module_locals[116])
	rt_memory_drop(module_locals[117])
	rt_memory_drop(module_locals[118])
	module_locals[2] = module_locals[1];
	module_locals[22] = module_locals[4];
	module_locals[113] = module_locals[3];
	local export = {
		["memory"] = module_locals[3],
		["_start"] = module_locals[4][1],
		["__host"] = runtime.host_api,
	}
	return export
end
return module
