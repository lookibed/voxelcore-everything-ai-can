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

	return (bit_or(bit_rshift(words[slot], shift), bit_lshift(words[slot + 1], 32 - shift)))
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

do -- SECTION multiply_f64
local function rt_multiply_f64(lhs, rhs)
	return lhs * rhs
end
	runtime.rt_multiply_f64 = rt_multiply_f64
end

do -- SECTION greater_than_equal_f64
local function rt_greater_than_equal_f64(lhs, rhs)
	return lhs >= rhs
end
	runtime.rt_greater_than_equal_f64 = rt_greater_than_equal_f64
end

do -- SECTION math_modf
local math_modf = math.modf
	runtime.math_modf = math_modf
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

do -- SECTION add_f64
local function rt_add_f64(lhs, rhs)
	return lhs + rhs
end
	runtime.rt_add_f64 = rt_add_f64
end

do -- SECTION force_s32
	local bit, bit_tobit = runtime.bit, runtime.bit_tobit
-- `bit.tobit` maps every `i32` representation (signed `-2 ^ 31 .. 2 ^ 31 - 1`
-- or unsigned `0 .. 2 ^ 32 - 1`) to the signed one without a branch; the old
-- two-branch form made a side trace wherever the sign of the value varied.
local force_s32 = bit_tobit
	runtime.force_s32 = force_s32
end

do -- SECTION convert_s32_to_f64
	local force_s32 = runtime.force_s32
local function rt_convert_s32_to_f64(source)
	return force_s32(source) + 0.0
end
	runtime.rt_convert_s32_to_f64 = rt_convert_s32_to_f64
end

do -- SECTION from_bits_i64
local function from_bits_i64(source)
	return source[1], source[2]
end
	runtime.from_bits_i64 = from_bits_i64
end

do -- SECTION into_bits_i64
local function into_bits_i64(lo, hi)
	return { lo % 4294967296, hi % 4294967296 }
end
	runtime.into_bits_i64 = into_bits_i64
end

do -- SECTION narrow_i64
	local from_bits_i64 = runtime.from_bits_i64
local function rt_narrow_i64(source)
	local lo, _ = from_bits_i64(source)

	return lo
end
	runtime.rt_narrow_i64 = rt_narrow_i64
end

do -- SECTION transmute_i64_to_f64
	local from_bits_f64, from_bits_i64, into_bits_i64, rt_narrow_i64 = runtime.from_bits_f64, runtime.from_bits_i64, runtime.into_bits_i64, runtime.rt_narrow_i64
local function rt_transmute_i64_to_f64(source)
	local lo, hi = from_bits_i64(source)

	return from_bits_f64(lo, hi)
end

-- The low word helpers below compute `rt_narrow_i64` of an operation from the
-- low words (unsigned numbers) of its operands, without making `i64` values;
-- each returns the low word the way `into_bits_i64` stores it.
	runtime.rt_transmute_i64_to_f64 = rt_transmute_i64_to_f64
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

do -- SECTION equal_i32
	local force_i32 = runtime.force_i32
local function rt_equal_i32(lhs, rhs)
	return force_i32(lhs) == force_i32(rhs)
end
	runtime.rt_equal_i32 = rt_equal_i32
end

do -- SECTION less_than_f64
local function rt_less_than_f64(lhs, rhs)
	return lhs < rhs
end
	runtime.rt_less_than_f64 = rt_less_than_f64
end

do -- SECTION greater_than_f64
local function rt_greater_than_f64(lhs, rhs)
	return lhs > rhs
end
	runtime.rt_greater_than_f64 = rt_greater_than_f64
end

do -- SECTION not_equal_f64
local function rt_not_equal_f64(lhs, rhs)
	return lhs ~= rhs
end
	runtime.rt_not_equal_f64 = rt_not_equal_f64
end

do -- SECTION and_i32
	local bit32_and = runtime.bit32_and
local rt_and_i32 = bit32_and
	runtime.rt_and_i32 = rt_and_i32
end

do -- SECTION negate_f64
local function rt_negate_f64(source)
	return -source
end
	runtime.rt_negate_f64 = rt_negate_f64
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

do -- SECTION transmute_f64_to_i64
	local into_bits_f64, into_bits_i64 = runtime.into_bits_f64, runtime.into_bits_i64
local function rt_transmute_f64_to_i64(source)
	local lo, hi = into_bits_f64(source)

	return into_bits_i64(lo, hi)
end
	runtime.rt_transmute_f64_to_i64 = rt_transmute_f64_to_i64
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

do -- SECTION and_i64
	local bit32_and, from_bits_i64, into_bits_i64 = runtime.bit32_and, runtime.from_bits_i64, runtime.into_bits_i64
local function rt_and_i64(lhs, rhs)
	local lhs_lo, lhs_hi = from_bits_i64(lhs)
	local rhs_lo, rhs_hi = from_bits_i64(rhs)

	return into_bits_i64(bit32_and(lhs_lo, rhs_lo), bit32_and(lhs_hi, rhs_hi))
end
	runtime.rt_and_i64 = rt_and_i64
end

do -- SECTION low_shift_right_u64
	local bit32_lshift, bit32_or, bit32_rshift, from_bits_i64 = runtime.bit32_lshift, runtime.bit32_or, runtime.bit32_rshift, runtime.from_bits_i64
-- `amount` is a constant in `0 .. 63`.
local function rt_low_shift_right_u64(source, amount)
	local lo, hi = from_bits_i64(source)

	if amount == 0 then
		return lo
	end

	if amount < 32 then
		return bit32_or(bit32_rshift(lo, amount), bit32_lshift(hi, 32 - amount)) % 4294967296
	end

	if amount == 32 then
		return hi
	end

	return bit32_rshift(hi, amount - 32) % 4294967296
end
	runtime.rt_low_shift_right_u64 = rt_low_shift_right_u64
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

do -- SECTION divide_f64
local function rt_divide_f64(lhs, rhs)
	return lhs / rhs
end
	runtime.rt_divide_f64 = rt_divide_f64
end

do -- SECTION equal_f64
local function rt_equal_f64(lhs, rhs)
	return lhs == rhs
end
	runtime.rt_equal_f64 = rt_equal_f64
end

do -- SECTION widen_f32
local function rt_widen_f32(source)
	return source
end
	runtime.rt_widen_f32 = rt_widen_f32
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

do -- SECTION math_abs
local math_abs = math.abs
	runtime.math_abs = math_abs
end

do -- SECTION math_huge
local math_huge = math.huge
	runtime.math_huge = math_huge
end

do -- SECTION round_f32
	local MIN_NORMAL_F32, OVERFLOW_F32, SPLIT_F32, SUB_MAGIC_F32, bit, math_abs, math_huge = runtime.MIN_NORMAL_F32, runtime.OVERFLOW_F32, runtime.SPLIT_F32, runtime.SUB_MAGIC_F32, runtime.bit, runtime.math_abs, runtime.math_huge
-- `--f32 number`: an `f32` value is a Lua number that holds a `binary32` value
-- exactly, instead of the `binary32` bit pattern. This file replaces, section
-- by section, every helper that produces or consumes an `f32`; the bits only
-- appear at the boundaries (`f32.load`, `f32.store`, `reinterpret`).
--
-- `round_f32` rounds a double to the nearest `binary32` (ties to even). For a
-- result of `+ - * /` or `sqrt` on two `binary32` operands done in double, this
-- double rounding is exact (double has more than `2 * 24 + 2` bits), so
-- `round_f32(a op b)` is the `f32` operation bit for bit.
--
-- The normal range takes the Veltkamp split (`SPLIT_F32` in `f32_constants`),
-- a multiply and two subtractions that stay in the trace; `math.abs` keeps the
-- guard free of a branch on the sign. Zero, subnormals, overflow and NaN go
-- to `round_f32_special`.
local function round_f32_special(source)
	if source ~= source then
		return source
	end

	local magnitude = math_abs(source)

	if magnitude >= OVERFLOW_F32 then
		if source > 0 then
			return math_huge
		end

		return -math_huge
	end

	-- A multiple of `2 ^ -149` with the same round-half-to-even rule; the sign
	-- is put back afterwards so `-0` and small negatives keep it.
	local rounded = (magnitude + SUB_MAGIC_F32) - SUB_MAGIC_F32

	if source < 0 or 1 / source < 0 then
		return -rounded
	end

	return rounded
end

local function round_f32(source)
	local magnitude = math_abs(source)

	if magnitude >= MIN_NORMAL_F32 and magnitude < OVERFLOW_F32 then
		local split = source * SPLIT_F32

		return split - (split - source)
	end

	return round_f32_special(source)
end
	runtime.round_f32_special = round_f32_special
	runtime.round_f32 = round_f32
end

do -- SECTION narrow_f64
	local round_f32 = runtime.round_f32
local function rt_narrow_f64(source)
	return round_f32(source)
end
	runtime.rt_narrow_f64 = rt_narrow_f64
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

	return (bit_and(bit_rshift(words[slot], shift), 65535))
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

do -- SECTION shift_left_i32
	local bit32_and, bit32_lshift = runtime.bit32_and, runtime.bit32_lshift
local function rt_shift_left_i32(lhs, rhs)
	rhs = bit32_and(rhs, 0x1F)

	local result = bit32_lshift(lhs, rhs)

	return result
end
	runtime.rt_shift_left_i32 = rt_shift_left_i32
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
	local bit, bit32_xor = runtime.bit, runtime.bit32_xor
-- Unsigned order is the signed order with the top bit flipped: no branch.
local function rt_less_than_u32(lhs, rhs)
	return bit32_xor(lhs, 0x80000000) < bit32_xor(rhs, 0x80000000)
end
	runtime.rt_less_than_u32 = rt_less_than_u32
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

	return (bit_and(bit_rshift(buf.__w[bit_rshift(index, 2) + 1], bit_lshift(bit_and(index, 3), 3)), 255))
end
	runtime.buffer_byte = buffer_byte
end

do -- SECTION buffer_read_u8
	local buffer_byte = runtime.buffer_byte
local function buffer_read_u8(buf, base, offset)
	return (buffer_byte(buf, base, offset))
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

do -- SECTION less_than_equal_s32
	local force_s32 = runtime.force_s32
local function rt_less_than_equal_s32(lhs, rhs)
	lhs = force_s32(lhs)
	rhs = force_s32(rhs)

	return lhs <= rhs
end
	runtime.rt_less_than_equal_s32 = rt_less_than_equal_s32
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

do -- SECTION or_i32
	local bit32_or = runtime.bit32_or
local rt_or_i32 = bit32_or
	runtime.rt_or_i32 = rt_or_i32
end

do -- SECTION bit32_arshift
	local bit = runtime.bit
local bit32_arshift = bit.arshift
	runtime.bit32_arshift = bit32_arshift
end

do -- SECTION buffer_read_i8
	local bit_and, buffer_byte = runtime.bit_and, runtime.buffer_byte
-- Sign extension without a branch: a data dependent branch here becomes a side
-- exit of every trace through a byte read, and in large traces LuaJIT cannot
-- compile the side trace ("register coalescing too complex") and retries it.
local function buffer_read_i8(buf, base, offset)
	local value = buffer_byte(buf, base, offset)

	return value - bit_and(value, 128) * 2
end
	runtime.buffer_read_i8 = buffer_read_i8
end

do -- SECTION extend_s8_to_i32
	local bit32_arshift, bit32_lshift, buffer_read_i8 = runtime.bit32_arshift, runtime.bit32_lshift, runtime.buffer_read_i8
-- Sign extension without a branch on the sign (see `buffer_read_i8`).
local function rt_extend_s8_to_i32(source)
	return bit32_arshift(bit32_lshift(source, 24), 24)
end
	runtime.rt_extend_s8_to_i32 = rt_extend_s8_to_i32
end

do -- SECTION greater_than_u32
	local bit, bit32_xor = runtime.bit, runtime.bit32_xor
-- Unsigned order is the signed order with the top bit flipped: no branch.
local function rt_greater_than_u32(lhs, rhs)
	return bit32_xor(lhs, 0x80000000) > bit32_xor(rhs, 0x80000000)
end
	runtime.rt_greater_than_u32 = rt_greater_than_u32
end

do -- SECTION greater_than_equal_u32
	local bit, bit32_xor = runtime.bit, runtime.bit32_xor
-- Unsigned order is the signed order with the top bit flipped: no branch.
local function rt_greater_than_equal_u32(lhs, rhs)
	return bit32_xor(lhs, 0x80000000) >= bit32_xor(rhs, 0x80000000)
end
	runtime.rt_greater_than_equal_u32 = rt_greater_than_equal_u32
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

do -- SECTION force_u32
-- The unsigned form of an `i32` representation, without a branch on the sign.
local function force_u32(source)
	return source % 0x100000000
end
	runtime.force_u32 = force_u32
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

do -- SECTION convert_s32_to_f32
	local bit_tobit, round_f32 = runtime.bit_tobit, runtime.round_f32
local function rt_convert_s32_to_f32(source)
	return round_f32(bit_tobit(source) + 0.0)
end
	runtime.rt_convert_s32_to_f32 = rt_convert_s32_to_f32
end

do -- SECTION convert_u32_to_f32
	local force_u32, round_f32 = runtime.force_u32, runtime.round_f32
local function rt_convert_u32_to_f32(source)
	return round_f32(force_u32(source) + 0.0)
end
	runtime.rt_convert_u32_to_f32 = rt_convert_u32_to_f32
end

do -- SECTION divide_f32
	local round_f32 = runtime.round_f32
local function rt_divide_f32(lhs, rhs)
	return round_f32(lhs / rhs)
end
	runtime.rt_divide_f32 = rt_divide_f32
end

do -- SECTION multiply_f32
	local round_f32 = runtime.round_f32
local function rt_multiply_f32(lhs, rhs)
	return round_f32(lhs * rhs)
end
	runtime.rt_multiply_f32 = rt_multiply_f32
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

do -- SECTION store_f32
	local buffer_write_i32, into_bits_f32 = runtime.buffer_write_i32, runtime.into_bits_f32
local function rt_store_f32(destination, base, offset, source)
	buffer_write_i32(destination[1], base, offset, into_bits_f32(source))
end
	runtime.rt_store_f32 = rt_store_f32
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

do -- SECTION load_f32
	local buffer_read_i32, from_bits_f32 = runtime.buffer_read_i32, runtime.from_bits_f32
local function rt_load_f32(source, base, offset)
	return from_bits_f32(buffer_read_i32(source[1], base, offset))
end
	runtime.rt_load_f32 = rt_load_f32
end

do -- SECTION load_i32_from_s8
	local buffer_read_i8 = runtime.buffer_read_i8
local function rt_load_i32_from_s8(source, base, offset)
	local result = buffer_read_i8(source[1], base, offset)

	return result
end
	runtime.rt_load_i32_from_s8 = rt_load_i32_from_s8
end

do -- SECTION add_f32
	local round_f32 = runtime.round_f32
local function rt_add_f32(lhs, rhs)
	return round_f32(lhs + rhs)
end
	runtime.rt_add_f32 = rt_add_f32
end

do -- SECTION math_sqrt
local math_sqrt = math.sqrt
	runtime.math_sqrt = math_sqrt
end

do -- SECTION square_root_f32
	local math_sqrt, round_f32 = runtime.math_sqrt, runtime.round_f32
local function rt_square_root_f32(source)
	return round_f32(math_sqrt(source))
end
	runtime.rt_square_root_f32 = rt_square_root_f32
end

do -- SECTION absolute_f32
	local math_abs = runtime.math_abs
local rt_absolute_f32 = math_abs
	runtime.rt_absolute_f32 = rt_absolute_f32
end

do -- SECTION greater_than_f32
local function rt_greater_than_f32(lhs, rhs)
	return lhs > rhs
end
	runtime.rt_greater_than_f32 = rt_greater_than_f32
end

do -- SECTION round_down_f32
	local math_floor = runtime.math_floor
local function rt_round_down_f32(source)
	return math_floor(source)
end
	runtime.rt_round_down_f32 = rt_round_down_f32
end

do -- SECTION negate_f32
local function rt_negate_f32(source)
	return -source
end
	runtime.rt_negate_f32 = rt_negate_f32
end

do -- SECTION subtract_f32
	local round_f32 = runtime.round_f32
local function rt_subtract_f32(lhs, rhs)
	return round_f32(lhs - rhs)
end
	runtime.rt_subtract_f32 = rt_subtract_f32
end

do -- SECTION greater_than_equal_f32
local function rt_greater_than_equal_f32(lhs, rhs)
	return lhs >= rhs
end
	runtime.rt_greater_than_equal_f32 = rt_greater_than_equal_f32
end

do -- SECTION saturate_f32_to_s32
	local rt_saturate_f64_to_s32 = runtime.rt_saturate_f64_to_s32
local function rt_saturate_f32_to_s32(source)
	return rt_saturate_f64_to_s32(source)
end
	runtime.rt_saturate_f32_to_s32 = rt_saturate_f32_to_s32
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

do -- SECTION exclusive_or_i64
	local bit32_xor, from_bits_i64, into_bits_i64 = runtime.bit32_xor, runtime.from_bits_i64, runtime.into_bits_i64
local function rt_exclusive_or_i64(lhs, rhs)
	local lhs_lo, lhs_hi = from_bits_i64(lhs)
	local rhs_lo, rhs_hi = from_bits_i64(rhs)

	return into_bits_i64(bit32_xor(lhs_lo, rhs_lo), bit32_xor(lhs_hi, rhs_hi))
end
	runtime.rt_exclusive_or_i64 = rt_exclusive_or_i64
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

do -- SECTION less_than_f32
local function rt_less_than_f32(lhs, rhs)
	return lhs < rhs
end
	runtime.rt_less_than_f32 = rt_less_than_f32
end

do -- SECTION less_than_equal_f32
local function rt_less_than_equal_f32(lhs, rhs)
	return lhs <= rhs
end
	runtime.rt_less_than_equal_f32 = rt_less_than_equal_f32
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

do -- SECTION convert_u32_to_f64
	local force_u32 = runtime.force_u32
local function rt_convert_u32_to_f64(source)
	return force_u32(source) + 0.0
end
	runtime.rt_convert_u32_to_f64 = rt_convert_u32_to_f64
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

do -- SECTION less_than_equal_u32
	local bit, bit32_xor = runtime.bit, runtime.bit32_xor
-- Unsigned order is the signed order with the top bit flipped: no branch.
local function rt_less_than_equal_u32(lhs, rhs)
	return bit32_xor(lhs, 0x80000000) <= bit32_xor(rhs, 0x80000000)
end
	runtime.rt_less_than_equal_u32 = rt_less_than_equal_u32
end

do -- SECTION equal_i64_constant
	local from_bits_i64 = runtime.from_bits_i64
local function rt_equal_i64_constant(source, lo, hi)
	local source_lo, source_hi = from_bits_i64(source)

	return source_lo == lo and source_hi == hi
end
	runtime.rt_equal_i64_constant = rt_equal_i64_constant
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

do -- SECTION greater_than_equal_s64
	local rt_less_than_s64 = runtime.rt_less_than_s64
local function rt_greater_than_equal_s64(lhs, rhs)
	return not rt_less_than_s64(lhs, rhs)
end
	runtime.rt_greater_than_equal_s64 = rt_greater_than_equal_s64
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

do -- SECTION store_i64_into_i32
	local buffer_write_i32, from_bits_i64 = runtime.buffer_write_i32, runtime.from_bits_i64
local function rt_store_i64_into_i32(destination, base, offset, source)
	local lo = from_bits_i64(source)

	buffer_write_i32(destination[1], base, offset, lo)
end
	runtime.rt_store_i64_into_i32 = rt_store_i64_into_i32
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

do -- SECTION buffer_read_f64
	local buffer_check, buffer_read_i32, from_bits_f64 = runtime.buffer_check, runtime.buffer_read_i32, runtime.from_bits_f64
local function buffer_read_f64(buf, base, offset)
	buffer_check(buf, base, offset, 8)

	local lo = buffer_read_i32(buf, base, offset)
	local hi = buffer_read_i32(buf, base, offset + 4)

	return (from_bits_f64(lo, hi))
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

do -- SECTION greater_than_s64
	local rt_less_than_s64 = runtime.rt_less_than_s64
local function rt_greater_than_s64(lhs, rhs)
	return rt_less_than_s64(rhs, lhs)
end
	runtime.rt_greater_than_s64 = rt_greater_than_s64
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

do -- SECTION subtract_f64
local function rt_subtract_f64(lhs, rhs)
	return lhs - rhs
end
	runtime.rt_subtract_f64 = rt_subtract_f64
end

do -- SECTION load_i64_from_u32
	local buffer_read_i32, into_bits_i64 = runtime.buffer_read_i32, runtime.into_bits_i64
local function rt_load_i64_from_u32(source, base, offset)
	local val = buffer_read_i32(source[1], base, offset)

	return into_bits_i64(val, 0)
end
	runtime.rt_load_i64_from_u32 = rt_load_i64_from_u32
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

do -- SECTION raw_divide_exact
	local math_floor = runtime.math_floor
-- Divides the integers `lhs` and `rhs` (`rhs >= 1`) in doubles, exactly: both
-- must be below `2 ^ 53` and `lhs + rhs` too. The rounded quotient is off by at
-- most one and every product and difference below is an exact integer, so the
-- correction makes quotient and remainder exact.
local function raw_divide_exact(lhs, rhs)
	local quotient = math_floor(lhs / rhs)
	local remainder = lhs - quotient * rhs

	if remainder < 0 then
		quotient = quotient - 1
		remainder = remainder + rhs
	elseif remainder >= rhs then
		quotient = quotient + 1
		remainder = remainder - rhs
	end

	return quotient, remainder
end
	runtime.raw_divide_exact = raw_divide_exact
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
	local bit, bit32_and, bit32_rshift, from_bits_i64, into_bits_i64, math_floor, raw_compare_u64, raw_divide_exact, raw_shift_left_one_u64, raw_subtract_u64 = runtime.bit, runtime.bit32_and, runtime.bit32_rshift, runtime.from_bits_i64, runtime.into_bits_i64, runtime.math_floor, runtime.raw_compare_u64, runtime.raw_divide_exact, runtime.raw_shift_left_one_u64, runtime.raw_subtract_u64
local function raw_unsigned_divide_u64(lhs, rhs)
	local lhs_lo, lhs_hi = from_bits_i64(lhs)
	local rhs_lo, rhs_hi = from_bits_i64(rhs)

	-- Fast paths in doubles, exact (see `raw_divide_exact`); the callers have
	-- already rejected a zero divisor.
	if rhs_hi == 0 and rhs_lo < 0x200000 then
		-- A divisor below `2 ^ 21` (`/ 1000`, `/ 1000000`): long division by
		-- 32 bit digits, where every partial dividend stays below `2 ^ 53`.
		local quotient_hi, carry = raw_divide_exact(lhs_hi, rhs_lo)
		local quotient_lo, remainder = raw_divide_exact(carry * 0x100000000 + lhs_lo, rhs_lo)

		return into_bits_i64(quotient_lo, quotient_hi), into_bits_i64(remainder, 0)
	end

	if lhs_hi < 0x100000 and rhs_hi < 0x100000 then
		-- Both operands below `2 ^ 52`.
		local quotient, remainder = raw_divide_exact(lhs_hi * 0x100000000 + lhs_lo, rhs_hi * 0x100000000 + rhs_lo)
		local quotient_hi = math_floor(quotient / 0x100000000)
		local remainder_hi = math_floor(remainder / 0x100000000)

		return into_bits_i64(quotient - quotient_hi * 0x100000000, quotient_hi),
			into_bits_i64(remainder - remainder_hi * 0x100000000, remainder_hi)
	end

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

do -- SECTION low_subtract_i64
local function rt_low_subtract_i64(lhs, rhs)
	return (lhs - rhs) % 4294967296
end
	runtime.rt_low_subtract_i64 = rt_low_subtract_i64
end

do -- SECTION low_multiply_i64
	local rt_multiply_i32 = runtime.rt_multiply_i32
local function rt_low_multiply_i64(lhs, rhs)
	return rt_multiply_i32(lhs, rhs) % 4294967296
end
	runtime.rt_low_multiply_i64 = rt_low_multiply_i64
end

do -- SECTION greater_than_equal_u64
	local rt_less_than_u64 = runtime.rt_less_than_u64
local function rt_greater_than_equal_u64(lhs, rhs)
	return not rt_less_than_u64(lhs, rhs)
end
	runtime.rt_greater_than_equal_u64 = rt_greater_than_equal_u64
end

do -- SECTION not_equal_i64_constant
	local from_bits_i64 = runtime.from_bits_i64
local function rt_not_equal_i64_constant(source, lo, hi)
	local source_lo, source_hi = from_bits_i64(source)

	return source_lo ~= lo or source_hi ~= hi
end
	runtime.rt_not_equal_i64_constant = rt_not_equal_i64_constant
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
	local bit_and, buffer_read_i8, buffer_read_u16 = runtime.bit_and, runtime.buffer_read_i8, runtime.buffer_read_u16
-- Sign extension without a branch, see `buffer_read_i8`.
local function buffer_read_i16(buf, base, offset)
	local value = buffer_read_u16(buf, base, offset)

	return value - bit_and(value, 32768) * 2
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
	return (from_bits_f32(buffer_read_i32(buf, base, offset)))
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
	local bit_and, bit_rshift, buffer, buffer_fill, buffer_len, buffer_read_f32, buffer_read_f64, buffer_read_i16, buffer_read_i32, buffer_read_i8, buffer_read_u16, buffer_read_u8, buffer_write_f32, buffer_write_f64, buffer_write_i32, buffer_write_u16, buffer_write_u8, buffer_writestring, rt_memory_new, yield_state = runtime.bit_and, runtime.bit_rshift, runtime.buffer, runtime.buffer_fill, runtime.buffer_len, runtime.buffer_read_f32, runtime.buffer_read_f64, runtime.buffer_read_i16, runtime.buffer_read_i32, runtime.buffer_read_i8, runtime.buffer_read_u16, runtime.buffer_read_u8, runtime.buffer_write_f32, runtime.buffer_write_f64, runtime.buffer_write_i32, runtime.buffer_write_u16, runtime.buffer_write_u8, runtime.buffer_writestring, runtime.rt_memory_new, runtime.yield_state
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

	-- A new linear memory object (the same format the module uses), for modules
	-- that import their memory (`env.memory`). Sizes are in bytes.
	function host_api.new_memory(min_bytes, max_bytes)
		return rt_memory_new({}, min_bytes, max_bytes or min_bytes)
	end

	-- Whether the module was built with yield points.
	host_api.has_yield_points = false
end
	runtime.host_api = host_api
end

do -- SECTION call_spread
-- Calls with many arguments (see `WIDE_CALL_ARGUMENTS`): the caller passes them in a
-- table, which a constructor fills in batches of 50 registers, and the spread happens
-- in this small frame, so the caller's frame stays under LuaJIT's 250 slot limit.
local function rt_call_spread(func, arguments, count)
	return func((unpack or table.unpack)(arguments, 1, count))
end
	runtime.rt_call_spread = rt_call_spread
end

local function module(loc_2292_)
	local excess_stack = { top = 0 }
	local rt_yield_budget = 20000
	runtime.host_api.has_yield_points = true
	local rt_absolute_f32 = runtime.rt_absolute_f32
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
	local rt_equal_i64_constant = runtime.rt_equal_i64_constant
	local rt_exclusive_or_i32 = runtime.rt_exclusive_or_i32
	local rt_exclusive_or_i64 = runtime.rt_exclusive_or_i64
	local rt_extend_s32_to_i64 = runtime.rt_extend_s32_to_i64
	local rt_extend_s8_to_i32 = runtime.rt_extend_s8_to_i32
	local from_bits_f64 = runtime.from_bits_f64
	local rt_function_type = runtime.rt_function_type
	local rt_greater_than_equal_f32 = runtime.rt_greater_than_equal_f32
	local rt_greater_than_equal_f64 = runtime.rt_greater_than_equal_f64
	local rt_greater_than_equal_s32 = runtime.rt_greater_than_equal_s32
	local rt_greater_than_equal_s64 = runtime.rt_greater_than_equal_s64
	local rt_greater_than_equal_u32 = runtime.rt_greater_than_equal_u32
	local rt_greater_than_equal_u64 = runtime.rt_greater_than_equal_u64
	local rt_greater_than_f32 = runtime.rt_greater_than_f32
	local rt_greater_than_f64 = runtime.rt_greater_than_f64
	local rt_greater_than_s32 = runtime.rt_greater_than_s32
	local rt_greater_than_s64 = runtime.rt_greater_than_s64
	local rt_greater_than_u32 = runtime.rt_greater_than_u32
	local rt_greater_than_u64 = runtime.rt_greater_than_u64
	local into_bits_i64 = runtime.into_bits_i64
	local rt_leading_zeroes_i32 = runtime.rt_leading_zeroes_i32
	local rt_less_than_equal_f32 = runtime.rt_less_than_equal_f32
	local rt_less_than_equal_s32 = runtime.rt_less_than_equal_s32
	local rt_less_than_equal_u32 = runtime.rt_less_than_equal_u32
	local rt_less_than_f32 = runtime.rt_less_than_f32
	local rt_less_than_f64 = runtime.rt_less_than_f64
	local rt_less_than_s32 = runtime.rt_less_than_s32
	local rt_less_than_s64 = runtime.rt_less_than_s64
	local rt_less_than_u32 = runtime.rt_less_than_u32
	local rt_less_than_u64 = runtime.rt_less_than_u64
	local rt_load_f32 = runtime.rt_load_f32
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
	local rt_low_multiply_i64 = runtime.rt_low_multiply_i64
	local rt_low_shift_right_u64 = runtime.rt_low_shift_right_u64
	local rt_low_subtract_i64 = runtime.rt_low_subtract_i64
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
	local rt_not_equal_i64_constant = runtime.rt_not_equal_i64_constant
	local rt_or_i32 = runtime.rt_or_i32
	local rt_or_i64 = runtime.rt_or_i64
	local rt_remainder_s32 = runtime.rt_remainder_s32
	local rt_remainder_u32 = runtime.rt_remainder_u32
	local rt_rotate_left_i32 = runtime.rt_rotate_left_i32
	local rt_round_down_f32 = runtime.rt_round_down_f32
	local rt_saturate_f32_to_s32 = runtime.rt_saturate_f32_to_s32
	local rt_saturate_f64_to_s32 = runtime.rt_saturate_f64_to_s32
	local rt_saturate_f64_to_u32 = runtime.rt_saturate_f64_to_u32
	local rt_shift_left_i32 = runtime.rt_shift_left_i32
	local rt_shift_left_i64 = runtime.rt_shift_left_i64
	local rt_shift_right_s32 = runtime.rt_shift_right_s32
	local rt_shift_right_u32 = runtime.rt_shift_right_u32
	local rt_shift_right_u64 = runtime.rt_shift_right_u64
	local rt_square_root_f32 = runtime.rt_square_root_f32
	local rt_store_f32 = runtime.rt_store_f32
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
	local rt_transmute_f64_to_i64 = runtime.rt_transmute_f64_to_i64
	local rt_transmute_i64_to_f64 = runtime.rt_transmute_i64_to_f64
	local rt_widen_f32 = runtime.rt_widen_f32
	local rt_widen_i32 = runtime.rt_widen_i32
	local rt_yield_point = runtime.rt_yield_point
	local module_locals = {}
	for i = 1, 168 do
		module_locals[i] = 0
	end
	do (function() --[[spider:chunk]]
	module_locals[5] = { assert(loc_2292_["vc"]["llm_status"], '`vc.llm_status` should be present') };
	module_locals[6] = { assert(loc_2292_["vc"]["time_ms"], '`vc.time_ms` should be present') };
	module_locals[7] = { assert(loc_2292_["vc"]["llm_param"], '`vc.llm_param` should be present') };
	module_locals[8] = { assert(loc_2292_["vc"]["llm_cmd"], '`vc.llm_cmd` should be present') };
	module_locals[9] = { assert(loc_2292_["vc"]["llm_poll"], '`vc.llm_poll` should be present') };
	module_locals[10] = { assert(loc_2292_["vc"]["frame_end"], '`vc.frame_end` should be present') };
	module_locals[11] = { assert(loc_2292_["vc"]["llm_logits"], '`vc.llm_logits` should be present') };
	module_locals[12] = { assert(loc_2292_["vc"]["llm_token"], '`vc.llm_token` should be present') };
	module_locals[13] = { assert(loc_2292_["vc"]["llm_emit"], '`vc.llm_emit` should be present') };
	module_locals[14] = { assert(loc_2292_["vc"]["llm_kprof"], '`vc.llm_kprof` should be present') };
	module_locals[15] = { assert(loc_2292_["vc"]["llm_matmul"], '`vc.llm_matmul` should be present') };
	module_locals[16] = { assert(loc_2292_["vc"]["llm_attention"], '`vc.llm_attention` should be present') };
	module_locals[17] = { assert(loc_2292_["wasi_snapshot_preview1"]["args_get"], '`wasi_snapshot_preview1.args_get` should be present') };
	module_locals[18] = { assert(loc_2292_["wasi_snapshot_preview1"]["args_sizes_get"], '`wasi_snapshot_preview1.args_sizes_get` should be present') };
	module_locals[19] = { assert(loc_2292_["wasi_snapshot_preview1"]["fd_close"], '`wasi_snapshot_preview1.fd_close` should be present') };
	module_locals[20] = { assert(loc_2292_["wasi_snapshot_preview1"]["fd_fdstat_get"], '`wasi_snapshot_preview1.fd_fdstat_get` should be present') };
	module_locals[21] = { assert(loc_2292_["wasi_snapshot_preview1"]["fd_fdstat_set_flags"], '`wasi_snapshot_preview1.fd_fdstat_set_flags` should be present') };
	module_locals[22] = { assert(loc_2292_["wasi_snapshot_preview1"]["fd_prestat_get"], '`wasi_snapshot_preview1.fd_prestat_get` should be present') };
	module_locals[23] = { assert(loc_2292_["wasi_snapshot_preview1"]["fd_prestat_dir_name"], '`wasi_snapshot_preview1.fd_prestat_dir_name` should be present') };
	module_locals[24] = { assert(loc_2292_["wasi_snapshot_preview1"]["fd_read"], '`wasi_snapshot_preview1.fd_read` should be present') };
	module_locals[25] = { assert(loc_2292_["wasi_snapshot_preview1"]["fd_seek"], '`wasi_snapshot_preview1.fd_seek` should be present') };
	module_locals[26] = { assert(loc_2292_["wasi_snapshot_preview1"]["fd_write"], '`wasi_snapshot_preview1.fd_write` should be present') };
	module_locals[27] = { assert(loc_2292_["wasi_snapshot_preview1"]["path_open"], '`wasi_snapshot_preview1.path_open` should be present') };
	module_locals[28] = { assert(loc_2292_["wasi_snapshot_preview1"]["proc_exit"], '`wasi_snapshot_preview1.proc_exit` should be present') };
	module_locals[29] = { nil };
	module_locals[29][1] = rt_function_type(--[[fn:__wasm_call_ctors]](function(loc_0_)
		local loc_1_
		loc_1_ = loc_0_;
		return loc_1_
	end), "->");
	module_locals[30] = { nil };
	module_locals[30][1] = rt_function_type(--[[fn:undefined_weak:__wasilibc_find_relpath_alloc]](function(loc_2_, loc_3_, loc_4_, loc_5_, loc_6_, loc_7_)
		local loc_8_, loc_9_
		loc_8_ = loc_7_;
		loc_9_ = error('unreachable code');
		return loc_2_, loc_8_
	end), "i32,i32,i32,i32,i32->i32");
	module_locals[4] = { nil };
	module_locals[73] = { nil };
	module_locals[85] = { nil };
	module_locals[86] = { nil };
	module_locals[88] = { nil };
	module_locals[165] = { nil };
	module_locals[3] = rt_memory_new({ }, 1114112, 4294967295);
	module_locals[4][1] = (function(loc_10_, loc_11_, loc_12_, loc_13_, loc_14_, loc_15_, loc_16_)
		return rt_function_type(--[[fn:_start]](function(loc_17_)
			local loc_18_, loc_19_, loc_20_, loc_21_, loc_22_, loc_23_, loc_24_, loc_25_, loc_26_, loc_27_
			loc_27_ = loc_15_[1];
			loc_19_ = loc_15_;
			loc_27_ = buffer_read_i32(loc_16_[1], bit32_or(loc_27_ + 10928, 0), 0);
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
				rt_store_i32(loc_20_, bit32_or(loc_27_ + 10928, 0), 0, 1)
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
	end)(module_locals[29], module_locals[73], module_locals[85], module_locals[86], module_locals[88], module_locals[165], module_locals[3]);
	module_locals[32] = { nil };
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[32][1] = rt_function_type(--[[fn:fm_exp]](function(loc_28_, loc_29_)
		local loc_30_, loc_31_, loc_32_, loc_33_, loc_34_
		if rt_not_equal_f64(loc_28_, loc_28_) then
			loc_30_ = loc_29_;
			loc_31_ = loc_28_;
			loc_32_ = 0;
		else
			loc_30_ = loc_29_;
			loc_31_ = loc_28_;
			if rt_equal_i32((rt_greater_than_f64(loc_31_, 7.097e2) and 1 or 0), 0) then
				loc_32_ = loc_31_;
				if rt_equal_i32((rt_less_than_f64(loc_32_, (-7.452e2)) and 1 or 0), 0) then
					loc_31_ = rt_multiply_f64(loc_32_, 1.4426950408889634e0);
					loc_33_ = 5e-1;
					loc_34_ = (-5e-1);
					if not (rt_greater_than_equal_f64(loc_31_, 0)) then
						loc_33_ = loc_34_;
					end
					loc_31_ = rt_saturate_f64_to_s32(rt_add_f64(loc_31_, loc_33_));
					loc_33_ = rt_convert_s32_to_f64(loc_31_);
					loc_33_ = rt_add_f64(rt_add_f64(loc_32_, rt_multiply_f64(loc_33_, (-6.931471803691238e-1))), rt_multiply_f64(loc_33_, (-1.9082149292705877e-10)));
					loc_33_ = rt_add_f64(rt_multiply_f64(loc_33_, rt_add_f64(rt_multiply_f64(loc_33_, rt_add_f64(rt_multiply_f64(loc_33_, rt_add_f64(rt_multiply_f64(loc_33_, rt_add_f64(rt_multiply_f64(loc_33_, rt_add_f64(rt_multiply_f64(loc_33_, rt_add_f64(rt_multiply_f64(loc_33_, rt_add_f64(rt_multiply_f64(loc_33_, rt_add_f64(rt_multiply_f64(loc_33_, rt_add_f64(rt_multiply_f64(loc_33_, rt_add_f64(rt_multiply_f64(loc_33_, rt_add_f64(rt_multiply_f64(loc_33_, rt_add_f64(rt_multiply_f64(loc_33_, rt_add_f64(rt_multiply_f64(loc_33_, 1.1470745597729725e-11), 1.6059043836821613e-10)), 2.08767569878681e-9)), 2.505210838544172e-8)), 2.755731922398589e-7)), 2.7557319223985893e-6)), 2.48015873015873e-5)), 1.984126984126984e-4)), 1.388888888888889e-3)), 8.333333333333333e-3)), 4.1666666666666664e-2)), 1.6666666666666666e-1)), 5e-1)), 1e0)), 1e0);
					if rt_less_than_s32(loc_31_, 1024) then
						if rt_greater_than_s32(loc_31_, -1023) then
							loc_32_ = 0;
							loc_31_ = rt_multiply_f64(loc_33_, rt_transmute_i64_to_f64(rt_shift_left_i64(rt_widen_i32(bit32_or(loc_31_ + 1023, 0)), 52)));
						else
							loc_32_ = 1;
							loc_31_ = rt_multiply_f64(rt_multiply_f64(loc_33_, 2.2250738585072014e-308), rt_transmute_i64_to_f64(rt_shift_left_i64(rt_widen_i32(bit32_or(loc_31_ + 2045, 0)), 52)));
						end
					else
						loc_32_ = 1;
						loc_31_ = rt_multiply_f64(rt_multiply_f64(loc_33_, 8.98846567431158e307), rt_transmute_i64_to_f64(rt_shift_left_i64(rt_widen_i32(loc_31_), 52)));
					end
				else
					loc_34_ = loc_32_;
					loc_32_ = 1;
					loc_31_ = 0;
				end
			else
				loc_34_ = loc_31_;
				loc_32_ = 1;
				loc_31_ = from_bits_f64(0, 2146435072) --[[ inf_f64 ]];
			end
		end
		if rt_not_equal_i32(loc_32_, 0) then
		end
		return loc_31_, loc_30_
	end), "f64->f64");
	module_locals[33] = { nil };
	module_locals[33][1] = rt_function_type(--[[fn:fm_sin]](function(loc_35_, loc_36_)
		local loc_37_, loc_38_, loc_39_, loc_40_, loc_41_
		loc_39_ = rt_multiply_f64(loc_35_, 6.366197723675814e-1);
		loc_40_ = 5e-1;
		loc_41_ = (-5e-1);
		if rt_greater_than_equal_f64(loc_39_, 0) then
			loc_37_ = loc_36_;
			loc_38_ = loc_35_;
		else
			loc_37_ = loc_36_;
			loc_38_ = loc_35_;
			loc_40_ = loc_41_;
		end
		loc_40_ = rt_saturate_f64_to_s32(rt_add_f64(loc_39_, loc_40_));
		loc_39_ = rt_convert_s32_to_f64(loc_40_);
		loc_39_ = rt_add_f64(rt_add_f64(rt_add_f64(loc_38_, rt_multiply_f64(loc_39_, (-1.5707963267341256e0))), rt_multiply_f64(loc_39_, (-6.077100506506192e-11))), rt_multiply_f64(loc_39_, (-2.0222662487959506e-21)));
		loc_38_ = rt_multiply_f64(loc_39_, loc_39_);
		loc_40_ = rt_and_i32(loc_40_, 3);
		if (loc_40_) >= 0 and (loc_40_) < 4 then
			if (loc_40_) < 2 then
				if (loc_40_) < 1 then
					loc_40_ = 0;
				else
					loc_40_ = 1;
					loc_38_ = rt_add_f64(rt_multiply_f64(loc_38_, rt_add_f64(rt_multiply_f64(loc_38_, rt_add_f64(rt_multiply_f64(loc_38_, rt_add_f64(rt_multiply_f64(loc_38_, rt_add_f64(rt_multiply_f64(loc_38_, rt_add_f64(rt_multiply_f64(loc_38_, rt_add_f64(rt_multiply_f64(loc_38_, rt_add_f64(rt_multiply_f64(loc_38_, 4.779477332387385e-14), (-1.1470745597729725e-11))), 2.08767569878681e-9)), (-2.755731922398589e-7))), 2.48015873015873e-5)), (-1.388888888888889e-3))), 4.1666666666666664e-2)), (-5e-1))), 1e0);
				end
			elseif (loc_40_) > 2 then
				loc_40_ = 1;
				loc_38_ = rt_negate_f64(rt_add_f64(rt_multiply_f64(loc_38_, rt_add_f64(rt_multiply_f64(loc_38_, rt_add_f64(rt_multiply_f64(loc_38_, rt_add_f64(rt_multiply_f64(loc_38_, rt_add_f64(rt_multiply_f64(loc_38_, rt_add_f64(rt_multiply_f64(loc_38_, rt_add_f64(rt_multiply_f64(loc_38_, rt_add_f64(rt_multiply_f64(loc_38_, 4.779477332387385e-14), (-1.1470745597729725e-11))), 2.08767569878681e-9)), (-2.755731922398589e-7))), 2.48015873015873e-5)), (-1.388888888888889e-3))), 4.1666666666666664e-2)), (-5e-1))), 1e0));
			else
				loc_40_ = 1;
				loc_38_ = rt_negate_f64(rt_add_f64(loc_39_, rt_multiply_f64(rt_multiply_f64(loc_39_, loc_38_), rt_add_f64(rt_multiply_f64(loc_38_, rt_add_f64(rt_multiply_f64(loc_38_, rt_add_f64(rt_multiply_f64(loc_38_, rt_add_f64(rt_multiply_f64(loc_38_, rt_add_f64(rt_multiply_f64(loc_38_, rt_add_f64(rt_multiply_f64(loc_38_, (-7.647163731819816e-13)), 1.6059043836821613e-10)), (-2.505210838544172e-8))), 2.7557319223985893e-6)), (-1.984126984126984e-4))), 8.333333333333333e-3)), (-1.6666666666666666e-1)))));
			end
		else
			loc_40_ = 0;
		end
		if not (rt_not_equal_i32(loc_40_, 0)) then
			loc_38_ = rt_add_f64(loc_39_, rt_multiply_f64(rt_multiply_f64(loc_39_, loc_38_), rt_add_f64(rt_multiply_f64(loc_38_, rt_add_f64(rt_multiply_f64(loc_38_, rt_add_f64(rt_multiply_f64(loc_38_, rt_add_f64(rt_multiply_f64(loc_38_, rt_add_f64(rt_multiply_f64(loc_38_, rt_add_f64(rt_multiply_f64(loc_38_, (-7.647163731819816e-13)), 1.6059043836821613e-10)), (-2.505210838544172e-8))), 2.7557319223985893e-6)), (-1.984126984126984e-4))), 8.333333333333333e-3)), (-1.6666666666666666e-1))));
		end
		return loc_38_, loc_37_
	end), "f64->f64");
	module_locals[34] = { nil };
	module_locals[34][1] = rt_function_type(--[[fn:fm_cos]](function(loc_42_, loc_43_)
		local loc_44_, loc_45_, loc_46_, loc_47_, loc_48_
		loc_46_ = rt_multiply_f64(loc_42_, 6.366197723675814e-1);
		loc_47_ = 5e-1;
		loc_48_ = (-5e-1);
		if rt_greater_than_equal_f64(loc_46_, 0) then
			loc_44_ = loc_43_;
			loc_45_ = loc_42_;
		else
			loc_44_ = loc_43_;
			loc_45_ = loc_42_;
			loc_47_ = loc_48_;
		end
		loc_47_ = rt_saturate_f64_to_s32(rt_add_f64(loc_46_, loc_47_));
		loc_46_ = rt_convert_s32_to_f64(loc_47_);
		loc_46_ = rt_add_f64(rt_add_f64(rt_add_f64(loc_45_, rt_multiply_f64(loc_46_, (-1.5707963267341256e0))), rt_multiply_f64(loc_46_, (-6.077100506506192e-11))), rt_multiply_f64(loc_46_, (-2.0222662487959506e-21)));
		loc_45_ = rt_multiply_f64(loc_46_, loc_46_);
		loc_47_ = rt_and_i32(loc_47_, 3);
		if (loc_47_) >= 0 and (loc_47_) < 4 then
			if (loc_47_) < 2 then
				if (loc_47_) < 1 then
					loc_47_ = loc_46_;
					loc_46_ = 0;
				else
					loc_47_ = loc_46_;
					loc_46_ = 1;
					loc_45_ = rt_negate_f64(rt_add_f64(loc_47_, rt_multiply_f64(rt_multiply_f64(loc_47_, loc_45_), rt_add_f64(rt_multiply_f64(loc_45_, rt_add_f64(rt_multiply_f64(loc_45_, rt_add_f64(rt_multiply_f64(loc_45_, rt_add_f64(rt_multiply_f64(loc_45_, rt_add_f64(rt_multiply_f64(loc_45_, rt_add_f64(rt_multiply_f64(loc_45_, (-7.647163731819816e-13)), 1.6059043836821613e-10)), (-2.505210838544172e-8))), 2.7557319223985893e-6)), (-1.984126984126984e-4))), 8.333333333333333e-3)), (-1.6666666666666666e-1)))));
				end
			elseif (loc_47_) > 2 then
				loc_47_ = loc_46_;
				loc_46_ = 1;
				loc_45_ = rt_add_f64(loc_47_, rt_multiply_f64(rt_multiply_f64(loc_47_, loc_45_), rt_add_f64(rt_multiply_f64(loc_45_, rt_add_f64(rt_multiply_f64(loc_45_, rt_add_f64(rt_multiply_f64(loc_45_, rt_add_f64(rt_multiply_f64(loc_45_, rt_add_f64(rt_multiply_f64(loc_45_, rt_add_f64(rt_multiply_f64(loc_45_, (-7.647163731819816e-13)), 1.6059043836821613e-10)), (-2.505210838544172e-8))), 2.7557319223985893e-6)), (-1.984126984126984e-4))), 8.333333333333333e-3)), (-1.6666666666666666e-1))));
			else
				loc_47_ = loc_46_;
				loc_46_ = 1;
				loc_45_ = rt_negate_f64(rt_add_f64(rt_multiply_f64(loc_45_, rt_add_f64(rt_multiply_f64(loc_45_, rt_add_f64(rt_multiply_f64(loc_45_, rt_add_f64(rt_multiply_f64(loc_45_, rt_add_f64(rt_multiply_f64(loc_45_, rt_add_f64(rt_multiply_f64(loc_45_, rt_add_f64(rt_multiply_f64(loc_45_, rt_add_f64(rt_multiply_f64(loc_45_, 4.779477332387385e-14), (-1.1470745597729725e-11))), 2.08767569878681e-9)), (-2.755731922398589e-7))), 2.48015873015873e-5)), (-1.388888888888889e-3))), 4.1666666666666664e-2)), (-5e-1))), 1e0));
			end
		else
			loc_46_ = 0;
		end
		if not (rt_not_equal_i32(loc_46_, 0)) then
			loc_45_ = rt_add_f64(rt_multiply_f64(loc_45_, rt_add_f64(rt_multiply_f64(loc_45_, rt_add_f64(rt_multiply_f64(loc_45_, rt_add_f64(rt_multiply_f64(loc_45_, rt_add_f64(rt_multiply_f64(loc_45_, rt_add_f64(rt_multiply_f64(loc_45_, rt_add_f64(rt_multiply_f64(loc_45_, rt_add_f64(rt_multiply_f64(loc_45_, 4.779477332387385e-14), (-1.1470745597729725e-11))), 2.08767569878681e-9)), (-2.755731922398589e-7))), 2.48015873015873e-5)), (-1.388888888888889e-3))), 4.1666666666666664e-2)), (-5e-1))), 1e0);
		end
		return loc_45_, loc_44_
	end), "f64->f64");
	module_locals[35] = { nil };
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[35][1] = (function(loc_49_)
		return rt_function_type(--[[fn:fm_pow]](function(loc_50_, loc_51_, loc_52_)
			local loc_53_, loc_54_, loc_55_, loc_56_, loc_57_, loc_58_, loc_59_, loc_60_
			loc_54_ = 1e0;
			if rt_equal_f64(loc_51_, 0) then
				loc_53_ = loc_52_;
				loc_55_ = loc_49_;
				loc_56_ = loc_50_;
				loc_57_ = loc_51_;
			else
				loc_55_ = loc_49_;
				loc_56_ = loc_50_;
				loc_57_ = loc_51_;
				loc_59_ = loc_52_;
				loc_60_ = loc_54_;
				loc_56_ = rt_transmute_f64_to_i64(loc_56_);
				loc_60_ = rt_transmute_i64_to_f64(rt_or_i64(rt_and_i64(loc_56_, into_bits_i64(4294967295, 1048575)), into_bits_i64(0, 1072693248)));
				loc_54_ = (rt_greater_than_f64(loc_60_, 1.4142135623730951e0) and 1 or 0);
				loc_58_ = -1022;
				loc_53_ = -1023;
				if rt_not_equal_i32(loc_54_, 0) then
					loc_55_, loc_60_ = loc_60_, loc_55_;
					loc_57_, loc_59_ = loc_59_, loc_57_;
				else
					loc_55_, loc_60_ = loc_60_, loc_55_;
					loc_57_, loc_59_ = loc_59_, loc_57_;
					loc_58_ = loc_53_;
				end
				loc_56_ = rt_convert_s32_to_f64(bit32_or(loc_58_ + rt_and_i32(rt_low_shift_right_u64(loc_56_, 52), 2047), 0));
				loc_58_ = rt_multiply_f64(loc_56_, 1.9082149292705877e-10);
				loc_53_ = rt_multiply_f64(loc_56_, 6.931471803691238e-1);
				loc_56_ = rt_multiply_f64(loc_55_, 5e-1);
				if not (rt_not_equal_i32(loc_54_, 0)) then
					loc_56_ = loc_55_;
				end
				loc_55_ = loc_60_;
				loc_54_ = rt_divide_f64(rt_add_f64(loc_56_, (-1e0)), rt_add_f64(loc_56_, 1e0));
				loc_56_ = rt_multiply_f64(loc_54_, loc_54_);
				loc_54_ = loc_60_[1](rt_multiply_f64(loc_59_, rt_add_f64(loc_58_, rt_add_f64(loc_53_, rt_multiply_f64(rt_add_f64(loc_54_, loc_54_), rt_add_f64(rt_multiply_f64(loc_56_, rt_add_f64(rt_multiply_f64(loc_56_, rt_add_f64(rt_multiply_f64(loc_56_, rt_add_f64(rt_multiply_f64(loc_56_, rt_add_f64(rt_multiply_f64(loc_56_, rt_add_f64(rt_multiply_f64(loc_56_, rt_add_f64(rt_multiply_f64(loc_56_, rt_add_f64(rt_multiply_f64(loc_56_, rt_add_f64(rt_multiply_f64(loc_56_, rt_add_f64(rt_multiply_f64(loc_56_, rt_add_f64(rt_multiply_f64(loc_56_, rt_add_f64(rt_multiply_f64(loc_56_, 4e-2), 4.3478260869565216e-2)), 4.7619047619047616e-2)), 5.263157894736842e-2)), 5.8823529411764705e-2)), 6.666666666666667e-2)), 7.692307692307693e-2)), 9.090909090909091e-2)), 1.111111111111111e-1)), 1.4285714285714285e-1)), 2e-1)), 3.333333333333333e-1)), 1e0))))), loc_57_)
			end
			return loc_54_, loc_53_
		end), "f64,f64->f64")
	end)(module_locals[32]);
	module_locals[36] = { nil };
	module_locals[36][1] = (function(loc_61_)
		return rt_function_type(--[[fn:fm_expf]](function(loc_62_, loc_63_)
			local loc_64_, loc_65_
			loc_65_ = loc_63_;
			loc_65_ = loc_61_[1](rt_widen_f32(loc_62_), loc_65_)
			return rt_narrow_f64(loc_65_), loc_64_
		end), "f32->f32")
	end)(module_locals[32]);
	module_locals[37] = { nil };
	module_locals[37][1] = (function(loc_66_)
		return rt_function_type(--[[fn:fm_sinf]](function(loc_67_, loc_68_)
			local loc_69_, loc_70_
			loc_70_ = loc_68_;
			loc_70_ = loc_66_[1](rt_widen_f32(loc_67_), loc_70_)
			return rt_narrow_f64(loc_70_), loc_69_
		end), "f32->f32")
	end)(module_locals[33]);
	module_locals[38] = { nil };
	module_locals[38][1] = (function(loc_71_)
		return rt_function_type(--[[fn:fm_cosf]](function(loc_72_, loc_73_)
			local loc_74_, loc_75_
			loc_75_ = loc_73_;
			loc_75_ = loc_71_[1](rt_widen_f32(loc_72_), loc_75_)
			return rt_narrow_f64(loc_75_), loc_74_
		end), "f32->f32")
	end)(module_locals[34]);
	module_locals[39] = { nil };
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[39][1] = (function(loc_76_)
		return rt_function_type(--[[fn:fm_powf]](function(loc_77_, loc_78_, loc_79_)
			local loc_80_, loc_81_
			loc_81_ = loc_79_;
			loc_81_ = loc_76_[1](rt_widen_f32(loc_77_), rt_widen_f32(loc_78_), loc_81_)
			return rt_narrow_f64(loc_81_), loc_80_
		end), "f32,f32->f32")
	end)(module_locals[35]);
	module_locals[40] = { nil };
	module_locals[90] = { nil };
	module_locals[111] = { nil };
	module_locals[114] = { nil };
	module_locals[156] = { nil };
	module_locals[161] = { nil };
	module_locals[164] = { nil };
	end)() end --[[/spider:chunk]]
	module_locals[40][1] = (function(loc_82_, loc_83_, loc_84_, loc_85_, loc_86_, loc_87_, loc_88_)
		return rt_function_type(--[[fn:tok_load]](function(loc_89_, loc_90_, loc_91_)
			local loc_92_, loc_93_, loc_94_, loc_95_, loc_96_, loc_97_, loc_98_, loc_99_, loc_100_, loc_101_, loc_102_, loc_103_, loc_104_, loc_105_, loc_106_, loc_107_, loc_108_, loc_109_, loc_110_, loc_111_, loc_112_, loc_113_, loc_114_, loc_115_, loc_116_, loc_117_
			loc_117_ = loc_87_[1];
			loc_94_ = loc_87_;
			loc_96_ = bit32_or(loc_117_ - 16, 0);
			loc_94_[1] = loc_96_;
			loc_102_ = 0;
			loc_103_ = 0;
			loc_105_ = 0;
			if rt_equal_i32(1076, 0) then
				loc_95_ = loc_88_;
				loc_97_ = loc_82_;
				loc_98_ = loc_83_;
				loc_99_ = loc_84_;
				loc_100_ = loc_85_;
				loc_101_ = loc_86_;
				loc_104_ = loc_89_;
				loc_116_ = loc_90_;
				loc_117_ = loc_91_;
			else
				loc_95_ = loc_88_;
				loc_97_ = loc_82_;
				loc_98_ = loc_83_;
				loc_99_ = loc_84_;
				loc_100_ = loc_85_;
				loc_101_ = loc_86_;
				loc_104_ = loc_89_;
				loc_116_ = loc_90_;
				loc_117_ = loc_91_;
				rt_memory_fill(loc_95_, loc_104_, 0, 1076)
			end
			loc_93_ = loc_98_[1](loc_116_, 1226, loc_117_)
			if rt_not_equal_i32(loc_93_, 0) then
				loc_117_ = loc_99_[1](bit32_or(loc_96_ + 8, 0), 1, 4, loc_93_, loc_117_)
				if rt_not_equal_i32(loc_117_, 4) then
					loc_102_ = 0;
				else
					loc_117_ = buffer_read_i32(loc_95_[1], loc_96_, 8);
					if rt_not_equal_i32(loc_117_, 1263817554) then
						loc_102_, loc_105_ = loc_105_, loc_102_;
						loc_103_, loc_104_ = loc_104_, loc_103_;
						loc_102_ = 0;
					else
						loc_102_, loc_105_ = loc_105_, loc_102_;
						loc_103_, loc_104_ = loc_104_, loc_103_;
						loc_117_ = loc_92_;
						loc_117_ = loc_99_[1](bit32_or(loc_96_ + 12, 0), 1, 4, loc_93_, loc_117_)
						if rt_not_equal_i32(loc_117_, 4) then
							loc_102_ = 0;
						else
							loc_117_ = buffer_read_i32(loc_95_[1], loc_96_, 12);
							if rt_not_equal_i32(loc_117_, 1) then
								loc_102_ = 0;
							else
								loc_117_ = loc_92_;
								loc_117_ = loc_99_[1](bit32_or(loc_96_ + 12, 0), 1, 4, loc_93_, loc_117_)
								if rt_not_equal_i32(loc_117_, 4) then
									loc_102_ = 0;
								else
									loc_116_ = loc_102_;
									loc_102_ = buffer_read_i32(loc_95_[1], loc_96_, 12);
									loc_117_ = loc_92_;
									loc_117_ = loc_99_[1](bit32_or(loc_96_ + 12, 0), 1, 4, loc_93_, loc_117_)
									if rt_not_equal_i32(loc_117_, 4) then
										loc_106_ = loc_116_;
										loc_102_ = 0;
									else
										loc_106_ = loc_116_;
										loc_116_ = buffer_read_i32(loc_95_[1], loc_96_, 12);
										loc_117_ = loc_92_;
										loc_117_ = loc_99_[1](bit32_or(loc_96_ + 12, 0), 1, 4, loc_93_, loc_117_)
										if rt_not_equal_i32(loc_117_, 4) then
											loc_107_ = loc_106_;
											loc_106_ = loc_105_;
											loc_105_ = loc_104_;
											loc_104_ = loc_103_;
											loc_103_ = loc_102_;
											loc_102_ = loc_116_;
											loc_102_ = 0;
										else
											loc_107_ = loc_106_;
											loc_106_ = loc_105_;
											loc_105_ = loc_104_;
											loc_104_ = loc_103_;
											loc_103_ = loc_102_;
											loc_102_ = loc_116_;
											loc_116_ = buffer_read_i32(loc_95_[1], loc_96_, 12);
											rt_store_i32(loc_95_, loc_104_, 0, loc_103_)
											loc_117_ = loc_92_;
											loc_115_ = loc_101_[1](loc_103_, 4, loc_117_)
											rt_store_i32(loc_95_, loc_104_, 4, loc_115_)
											loc_117_ = loc_101_[1](loc_103_, 2, loc_117_)
											rt_store_i32(loc_95_, loc_104_, 8, loc_117_)
											loc_117_ = bit32_or(loc_104_ + 52, 0);
											if rt_equal_i32(1024, 0) then
												loc_108_ = loc_107_;
												loc_107_ = loc_106_;
												loc_106_ = loc_105_;
												loc_105_ = loc_104_;
												loc_104_ = loc_102_;
												loc_102_ = loc_117_;
												loc_117_ = loc_103_;
												loc_103_ = loc_116_;
											else
												loc_108_ = loc_107_;
												loc_107_ = loc_106_;
												loc_106_ = loc_105_;
												loc_105_ = loc_104_;
												loc_104_ = loc_102_;
												loc_102_ = loc_117_;
												loc_117_ = loc_103_;
												loc_103_ = loc_116_;
												rt_memory_fill(loc_95_, loc_102_, 255, 1024)
											end
											if rt_equal_i32(loc_117_, 0) then
												loc_117_ = 0;
											else
												loc_116_ = 0;
												loc_115_ = 0;
												repeat
													rt_yield_budget = rt_yield_budget - 1
													if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
													loc_114_ = loc_92_;
													loc_114_ = loc_99_[1](bit32_or(loc_96_ + 12, 0), 1, 2, loc_93_, loc_114_)
													if rt_not_equal_i32(loc_114_, 2) then
														loc_113_ = loc_106_;
														loc_114_ = loc_107_;
														loc_114_ = 0;
														loc_106_ = 1;
													else
														loc_112_ = loc_108_;
														loc_113_ = loc_106_;
														loc_114_ = loc_107_;
														loc_108_ = rt_load_i32_from_u16(loc_95_, loc_96_, 12);
														loc_112_ = loc_92_;
														loc_112_ = loc_100_[1](bit32_or(loc_108_ + 1, 0), loc_112_)
														loc_111_ = buffer_read_i32(loc_95_[1], loc_105_, 4);
														rt_store_i32(loc_95_, bit32_or(loc_111_ + loc_115_, 0), 0, loc_112_)
														if rt_equal_i32(loc_108_, 0) then
															loc_106_ = loc_113_;
															loc_113_ = loc_112_;
															loc_112_ = 0;
														else
															loc_106_ = loc_113_;
															loc_113_ = loc_112_;
															loc_112_ = loc_92_;
															loc_112_ = loc_99_[1](loc_113_, 1, loc_108_, loc_93_, loc_112_)
															if rt_not_equal_i32(loc_112_, loc_108_) then
																loc_112_ = loc_106_;
																loc_112_ = 1;
																loc_114_ = 0;
																loc_106_ = 1;
															else
																loc_111_ = loc_106_;
																loc_113_ = buffer_read_i32(loc_95_[1], loc_105_, 4);
																loc_113_ = buffer_read_i32(loc_95_[1], bit32_or(loc_113_ + loc_115_, 0), 0);
																loc_112_ = 0;
																loc_106_ = loc_111_;
															end
														end
														if not (rt_not_equal_i32(loc_112_, 0)) then
															loc_112_ = loc_106_;
															rt_store_i32_into_i8(loc_95_, bit32_or(loc_113_ + loc_108_, 0), 0, 0)
															loc_114_ = buffer_read_i32(loc_95_[1], loc_105_, 8);
															rt_store_i32_into_i16(loc_95_, bit32_or(loc_114_ + loc_116_, 0), 0, loc_108_)
															loc_117_ = bit32_or(loc_117_ + -1, 0);
															loc_116_ = bit32_or(loc_116_ + 2, 0);
															loc_115_ = bit32_or(loc_115_ + 4, 0);
															if rt_not_equal_i32(loc_117_, 0) then
																loc_114_ = 1;
																loc_106_ = 65535;
															else
																loc_114_ = 0;
																loc_106_ = 0;
															end
														end
													end
													loc_107_ = loc_114_;
												until loc_114_ == 0
												if rt_not_equal_i32(loc_106_, 0) then
													loc_117_ = 1;
												else
													loc_117_ = 0;
												end
											end
											if rt_not_equal_i32(loc_117_, 0) then
												loc_102_ = 0;
											else
												loc_115_ = loc_104_;
												loc_116_ = loc_108_;
												rt_store_i32(loc_95_, loc_105_, 12, loc_115_)
												loc_108_ = loc_107_;
												loc_107_ = loc_106_;
												loc_106_ = loc_105_;
												loc_117_ = loc_115_;
												loc_105_ = loc_103_;
												loc_104_ = loc_102_;
												loc_115_ = rt_shift_left_i32(loc_115_, 1);
												loc_114_ = loc_116_;
												loc_113_ = 1;
												loc_116_ = loc_92_;
												repeat
													rt_yield_budget = rt_yield_budget - 1
													if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
													loc_111_ = loc_115_;
													loc_112_ = loc_113_;
													loc_115_ = loc_114_;
													loc_115_ = loc_111_;
													loc_114_ = loc_112_;
													loc_113_ = rt_shift_left_i32(loc_112_, 1);
												until not (rt_less_than_s32(loc_112_, loc_111_))
												loc_115_ = rt_shift_left_i32(loc_114_, 2);
												rt_store_i32(loc_95_, loc_106_, 32, bit32_or(loc_114_ + -1, 0))
												loc_116_ = loc_100_[1](loc_115_, loc_116_)
												rt_store_i32(loc_95_, loc_106_, 16, loc_116_)
												loc_112_ = loc_100_[1](loc_115_, loc_113_)
												rt_store_i32(loc_95_, loc_106_, 20, loc_112_)
												loc_112_ = loc_100_[1](loc_115_, loc_113_)
												rt_store_i32(loc_95_, loc_106_, 24, loc_112_)
												loc_113_ = loc_100_[1](loc_115_, loc_113_)
												rt_store_i32(loc_95_, loc_106_, 28, loc_113_)
												if not (rt_less_than_s32(loc_114_, 1)) then
													if not (rt_equal_i32(loc_115_, 0)) then
														rt_memory_fill(loc_95_, loc_116_, 255, loc_115_)
													end
												end
												if rt_equal_i32(loc_117_, 0) then
													loc_117_ = 0;
												else
													loc_116_ = 0;
													repeat
														rt_yield_budget = rt_yield_budget - 1
														if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
														loc_115_ = loc_92_;
														loc_115_ = loc_99_[1](bit32_or(loc_96_ + 12, 0), 1, 4, loc_93_, loc_115_)
														if rt_not_equal_i32(loc_115_, 4) then
															loc_114_ = loc_107_;
															loc_115_ = loc_108_;
															loc_115_ = 0;
															loc_107_ = 1;
														else
															loc_114_ = loc_107_;
															loc_115_ = loc_108_;
															loc_113_ = buffer_read_i32(loc_95_[1], loc_96_, 12);
															loc_112_ = loc_92_;
															loc_112_ = loc_99_[1](bit32_or(loc_96_ + 12, 0), 1, 4, loc_93_, loc_112_)
															if rt_not_equal_i32(loc_112_, 4) then
																loc_115_ = 0;
																loc_107_ = 1;
															else
																loc_112_ = buffer_read_i32(loc_95_[1], loc_96_, 12);
																loc_111_ = loc_92_;
																loc_111_ = loc_99_[1](bit32_or(loc_96_ + 12, 0), 1, 4, loc_93_, loc_111_)
																if rt_not_equal_i32(loc_111_, 4) then
																	loc_115_ = 0;
																	loc_107_ = 1;
																else
																	loc_111_ = buffer_read_i32(loc_95_[1], loc_96_, 12);
																	loc_108_ = buffer_read_i32(loc_95_[1], loc_106_, 16);
																	loc_103_ = buffer_read_i32(loc_95_[1], loc_106_, 32);
																	loc_110_ = rt_exclusive_or_i32(bit32_or(rt_multiply_i32(loc_112_, 40503) + 990598335, 0), rt_multiply_i32(loc_113_, -1640531535));
																	loc_109_ = rt_and_i32(rt_exclusive_or_i32(rt_shift_right_u32(loc_110_, 15), loc_110_), loc_103_);
																	loc_110_ = bit32_or(loc_108_ + rt_shift_left_i32(loc_109_, 2), 0);
																	loc_107_ = buffer_read_i32(loc_95_[1], loc_110_, 0);
																	if rt_equal_i32(loc_107_, -1) then
																		loc_109_, loc_114_ = loc_114_, loc_109_;
																		loc_114_, loc_113_ = loc_113_, loc_114_;
																		loc_110_, loc_115_ = loc_115_, loc_110_;
																		loc_110_ = 0;
																	else
																		loc_109_, loc_115_ = loc_115_, loc_109_;
																		loc_115_, loc_110_ = loc_110_, loc_115_;
																		loc_110_, loc_114_ = loc_114_, loc_110_;
																		loc_114_, loc_113_ = loc_113_, loc_114_;
																		repeat
																			rt_yield_budget = rt_yield_budget - 1
																			if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																			if rt_not_equal_i32(loc_107_, loc_114_) then
																				loc_102_ = loc_109_;
																				loc_109_ = 0;
																			else
																				loc_102_ = loc_109_;
																				loc_109_ = buffer_read_i32(loc_95_[1], loc_106_, 20);
																				loc_109_ = buffer_read_i32(loc_95_[1], bit32_or(loc_109_ + rt_shift_left_i32(loc_113_, 2), 0), 0);
																				if rt_equal_i32(loc_109_, loc_112_) then
																					loc_109_ = loc_110_;
																					loc_110_ = loc_102_;
																					loc_109_ = 1;
																					loc_102_ = 0;
																					loc_110_ = 1;
																				else
																					loc_109_ = 0;
																				end
																			end
																			if not (rt_not_equal_i32(loc_109_, 0)) then
																				loc_109_ = loc_115_;
																				loc_115_ = loc_102_;
																				loc_113_ = rt_and_i32(bit32_or(loc_113_ + 1, 0), loc_103_);
																				loc_115_ = bit32_or(loc_108_ + rt_shift_left_i32(loc_113_, 2), 0);
																				loc_107_ = buffer_read_i32(loc_95_[1], loc_115_, 0);
																				if rt_not_equal_i32(loc_107_, -1) then
																					loc_102_ = 1;
																					loc_110_ = 65535;
																				else
																					loc_102_ = 0;
																					loc_110_ = 0;
																				end
																			end
																			loc_109_ = loc_102_;
																		until loc_102_ == 0
																		if rt_not_equal_i32(loc_110_, 0) then
																			loc_110_ = 1;
																		else
																			loc_110_ = 0;
																		end
																	end
																	if not (rt_not_equal_i32(loc_110_, 0)) then
																		rt_store_i32(loc_95_, loc_115_, 0, loc_114_)
																		loc_115_ = buffer_read_i32(loc_95_[1], loc_106_, 20);
																		loc_114_ = rt_shift_left_i32(loc_113_, 2);
																		rt_store_i32(loc_95_, bit32_or(loc_115_ + loc_114_, 0), 0, loc_112_)
																		loc_115_ = buffer_read_i32(loc_95_[1], loc_106_, 24);
																		rt_store_i32(loc_95_, bit32_or(loc_115_ + loc_114_, 0), 0, loc_116_)
																		loc_115_ = buffer_read_i32(loc_95_[1], loc_106_, 28);
																		rt_store_i32(loc_95_, bit32_or(loc_115_ + loc_114_, 0), 0, loc_111_)
																	end
																	loc_116_ = bit32_or(loc_116_ + 1, 0);
																	if rt_not_equal_i32(loc_116_, loc_117_) then
																		loc_115_ = 1;
																		loc_107_ = 65535;
																	else
																		loc_115_ = 0;
																		loc_107_ = 0;
																	end
																end
															end
														end
														loc_108_ = loc_115_;
													until loc_115_ == 0
													if rt_not_equal_i32(loc_107_, 0) then
														loc_117_ = 1;
													else
														loc_117_ = 0;
													end
												end
												if rt_not_equal_i32(loc_117_, 0) then
													loc_102_ = 0;
												else
													rt_store_i32(loc_95_, loc_106_, 36, loc_105_)
													loc_117_ = loc_92_;
													loc_116_ = loc_101_[1](loc_105_, 4, loc_117_)
													rt_store_i32(loc_95_, loc_106_, 40, loc_116_)
													loc_116_ = loc_101_[1](loc_105_, 4, loc_117_)
													rt_store_i32(loc_95_, loc_106_, 44, loc_116_)
													loc_117_ = loc_101_[1](loc_105_, 4, loc_117_)
													rt_store_i32(loc_95_, loc_106_, 48, loc_117_)
													if rt_equal_i32(loc_105_, 0) then
														loc_115_ = loc_105_;
														loc_116_ = loc_107_;
														loc_107_ = loc_104_;
														loc_117_ = loc_108_;
														loc_108_ = loc_106_;
														loc_117_ = 0;
													else
														loc_115_ = loc_105_;
														loc_116_ = loc_108_;
														loc_108_ = loc_106_;
														loc_117_ = loc_107_;
														loc_107_ = loc_104_;
														loc_114_ = 0;
														repeat
															rt_yield_budget = rt_yield_budget - 1
															if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
															loc_113_ = loc_92_;
															loc_113_ = loc_99_[1](bit32_or(loc_96_ + 12, 0), 1, 4, loc_93_, loc_113_)
															if rt_not_equal_i32(loc_113_, 4) then
																loc_116_, loc_117_ = loc_117_, loc_116_;
																loc_113_ = 0;
																loc_117_ = 1;
															else
																loc_116_, loc_117_ = loc_117_, loc_116_;
																loc_113_ = buffer_read_i32(loc_95_[1], loc_96_, 12);
																loc_112_ = loc_92_;
																loc_112_ = loc_99_[1](bit32_or(loc_96_ + 12, 0), 1, 2, loc_93_, loc_112_)
																if rt_not_equal_i32(loc_112_, 2) then
																	loc_113_ = 0;
																	loc_117_ = 1;
																else
																	loc_112_ = rt_load_i32_from_u16(loc_95_, loc_96_, 12);
																	loc_111_ = buffer_read_i32(loc_95_[1], loc_108_, 40);
																	rt_store_i32(loc_95_, bit32_or(loc_111_ + loc_114_, 0), 0, loc_113_)
																	loc_113_ = loc_92_;
																	loc_113_ = loc_100_[1](bit32_or(loc_112_ + 1, 0), loc_113_)
																	loc_111_ = buffer_read_i32(loc_95_[1], loc_108_, 44);
																	rt_store_i32(loc_95_, bit32_or(loc_111_ + loc_114_, 0), 0, loc_113_)
																	if rt_equal_i32(loc_112_, 0) then
																		loc_113_, loc_117_ = loc_117_, loc_113_;
																		loc_117_, loc_116_ = loc_116_, loc_117_;
																		loc_111_ = 0;
																	else
																		loc_113_, loc_117_ = loc_117_, loc_113_;
																		loc_117_, loc_116_ = loc_116_, loc_117_;
																		loc_111_ = loc_92_;
																		loc_111_ = loc_99_[1](loc_116_, 1, loc_112_, loc_93_, loc_111_)
																		if rt_not_equal_i32(loc_111_, loc_112_) then
																			loc_113_, loc_117_ = loc_117_, loc_113_;
																			loc_111_ = 1;
																			loc_113_ = 0;
																			loc_117_ = 1;
																		else
																			loc_116_ = buffer_read_i32(loc_95_[1], loc_108_, 44);
																			loc_116_ = buffer_read_i32(loc_95_[1], bit32_or(loc_116_ + loc_114_, 0), 0);
																			loc_111_ = 0;
																		end
																	end
																	if not (rt_not_equal_i32(loc_111_, 0)) then
																		loc_113_, loc_117_ = loc_117_, loc_113_;
																		rt_store_i32_into_i8(loc_95_, bit32_or(loc_116_ + loc_112_, 0), 0, 0)
																		loc_117_ = buffer_read_i32(loc_95_[1], loc_108_, 48);
																		rt_store_i32(loc_95_, bit32_or(loc_117_ + loc_114_, 0), 0, loc_112_)
																		loc_115_ = bit32_or(loc_115_ + -1, 0);
																		loc_114_ = bit32_or(loc_114_ + 4, 0);
																		if rt_not_equal_i32(loc_115_, 0) then
																			loc_113_ = 1;
																			loc_117_ = 65535;
																		else
																			loc_113_ = 0;
																			loc_117_ = 0;
																		end
																	end
																end
															end
															loc_116_ = loc_113_;
														until loc_113_ == 0
														if rt_not_equal_i32(loc_117_, 0) then
															loc_117_ = 1;
														else
															loc_117_ = 0;
														end
													end
													if rt_not_equal_i32(loc_117_, 0) then
														loc_102_ = 0;
													else
														loc_117_ = loc_92_;
														loc_117_ = loc_97_[1](loc_93_, loc_117_)
														loc_106_ = buffer_read_i32(loc_95_[1], loc_108_, 0);
														if not (rt_less_than_s32(loc_106_, 1)) then
															loc_115_ = loc_107_;
															loc_116_ = loc_93_;
															loc_117_ = loc_106_;
															loc_116_ = buffer_read_i32(loc_95_[1], loc_108_, 36);
															loc_93_ = loc_116_;
															loc_107_ = (rt_less_than_u32(loc_116_, 4) and 1 or 0);
															loc_106_ = loc_115_;
															loc_105_ = rt_and_i32(loc_116_, 2147483644);
															loc_104_ = 0;
															loc_103_ = (rt_less_than_s32(loc_116_, 1) and 1 or 0);
															loc_102_ = rt_and_i32(loc_116_, 3);
															loc_109_ = loc_117_;
															repeat
																rt_yield_budget = rt_yield_budget - 1
																if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																if rt_not_equal_i32(loc_103_, 0) then
																	loc_110_ = loc_104_;
																	loc_111_ = loc_109_;
																	loc_109_ = 0;
																else
																	loc_110_ = loc_104_;
																	loc_111_ = loc_109_;
																	loc_104_ = buffer_read_i32(loc_95_[1], loc_108_, 40);
																	loc_112_ = 0;
																	loc_109_ = 0;
																	if not (rt_not_equal_i32(loc_107_, 0)) then
																		loc_115_ = loc_109_;
																		loc_116_ = loc_112_;
																		loc_117_ = loc_93_;
																		loc_93_ = loc_104_;
																		loc_112_ = 0;
																		loc_109_ = 0;
																		repeat
																			rt_yield_budget = rt_yield_budget - 1
																			if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																			loc_117_ = loc_109_;
																			loc_113_ = buffer_read_i32(loc_95_[1], loc_93_, 0);
																			loc_109_ = 1;
																			loc_114_ = 1;
																			loc_116_ = 1;
																			loc_115_ = 1;
																			if rt_equal_i32(loc_113_, loc_110_) then
																				loc_113_ = loc_112_;
																				loc_112_ = loc_93_;
																				loc_93_ = loc_116_;
																				loc_116_ = loc_117_;
																				loc_105_, loc_114_ = loc_114_, loc_105_;
																			else
																				loc_113_ = loc_112_;
																				loc_112_ = loc_93_;
																				loc_93_ = loc_116_;
																				loc_116_ = loc_117_;
																				loc_105_, loc_114_ = loc_114_, loc_105_;
																				loc_115_ = loc_116_;
																			end
																			loc_116_ = buffer_read_i32(loc_95_[1], bit32_or(loc_112_ + 4, 0), 0);
																			if not (rt_equal_i32(loc_116_, loc_110_)) then
																				loc_93_ = loc_115_;
																			end
																			loc_115_ = buffer_read_i32(loc_95_[1], bit32_or(loc_112_ + 8, 0), 0);
																			if not (rt_equal_i32(loc_115_, loc_110_)) then
																				loc_105_ = loc_93_;
																			end
																			loc_93_ = buffer_read_i32(loc_95_[1], bit32_or(loc_112_ + 12, 0), 0);
																			if not (rt_equal_i32(loc_93_, loc_110_)) then
																				loc_109_ = loc_105_;
																			end
																			loc_93_ = bit32_or(loc_112_ + 16, 0);
																			loc_105_ = loc_114_;
																			loc_113_ = bit32_or(loc_113_ + 4, 0);
																			loc_112_ = loc_113_;
																		until not (rt_not_equal_i32(loc_114_, loc_113_))
																	end
																	if not (rt_equal_i32(loc_102_, 0)) then
																		loc_113_ = loc_93_;
																		loc_93_ = bit32_or(loc_104_ + rt_shift_left_i32(loc_112_, 2), 0);
																		loc_112_ = loc_102_;
																		repeat
																			rt_yield_budget = rt_yield_budget - 1
																			if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																			loc_113_ = loc_109_;
																			loc_104_ = buffer_read_i32(loc_95_[1], loc_93_, 0);
																			loc_109_ = 1;
																			if rt_equal_i32(loc_104_, loc_110_) then
																				loc_104_ = loc_93_;
																				loc_93_ = loc_113_;
																			else
																				loc_104_ = loc_93_;
																				loc_93_ = loc_113_;
																				loc_109_ = loc_93_;
																			end
																			loc_93_ = bit32_or(loc_104_ + 4, 0);
																			loc_104_ = bit32_or(loc_112_ + -1, 0);
																			loc_112_ = loc_104_;
																		until loc_104_ == 0
																	end
																	if rt_not_equal_i32(loc_109_, 0) then
																		loc_109_ = 1;
																	else
																		loc_109_ = 0;
																	end
																end
																if not (rt_not_equal_i32(loc_109_, 0)) then
																	loc_109_ = buffer_read_i32(loc_95_[1], loc_108_, 8);
																	loc_109_ = rt_load_i32_from_u16(loc_95_, bit32_or(loc_109_ + rt_shift_left_i32(loc_110_, 1), 0), 0);
																	if not (rt_not_equal_i32(loc_109_, 1)) then
																		loc_109_ = loc_93_;
																		loc_109_ = buffer_read_i32(loc_95_[1], loc_108_, 4);
																		loc_109_ = buffer_read_i32(loc_95_[1], bit32_or(loc_109_ + rt_shift_left_i32(loc_110_, 2), 0), 0);
																		loc_109_ = rt_load_i32_from_u8(loc_95_, loc_109_, 0);
																		loc_93_ = bit32_or(loc_106_ + rt_shift_left_i32(loc_109_, 2), 0);
																		loc_109_ = buffer_read_i32(loc_95_[1], loc_93_, 0);
																		if not (rt_greater_than_s32(loc_109_, -1)) then
																			rt_store_i32(loc_95_, loc_93_, 0, loc_110_)
																		end
																	end
																end
																loc_110_ = bit32_or(loc_110_ + 1, 0);
																loc_104_ = loc_110_;
																loc_109_ = loc_111_;
															until not (rt_not_equal_i32(loc_110_, loc_111_))
														end
														loc_107_ = 0;
														repeat
															rt_yield_budget = rt_yield_budget - 1
															if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
															loc_106_ = loc_93_;
															loc_106_ = bit32_or(loc_108_ + loc_107_, 0);
															loc_105_ = buffer_read_i32(loc_95_[1], bit32_or(loc_106_ + 52, 0), 0);
															loc_93_ = 3;
															if rt_less_than_s32(loc_105_, 0) then
																loc_106_ = 0;
															else
																loc_105_ = buffer_read_i32(loc_95_[1], bit32_or(loc_106_ + 56, 0), 0);
																if rt_less_than_s32(loc_105_, 0) then
																	loc_106_ = 0;
																else
																	loc_105_ = buffer_read_i32(loc_95_[1], bit32_or(loc_106_ + 60, 0), 0);
																	if rt_less_than_s32(loc_105_, 0) then
																		loc_106_ = 0;
																	else
																		loc_106_ = buffer_read_i32(loc_95_[1], bit32_or(loc_106_ + 64, 0), 0);
																		if rt_less_than_s32(loc_106_, 0) then
																			loc_106_ = 0;
																		else
																			loc_106_ = loc_93_;
																			loc_93_ = 0;
																			loc_107_ = bit32_or(loc_107_ + 16, 0);
																			if rt_equal_i32(loc_107_, 1024) then
																				loc_106_ = 0;
																			else
																				loc_106_ = 1;
																			end
																		end
																	end
																end
															end
														until loc_106_ == 0
														loc_102_ = 1;
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
				if not (rt_not_equal_i32(loc_102_, 0)) then
					loc_102_ = loc_97_;
					loc_97_ = loc_102_;
					loc_93_ = loc_102_[1](loc_93_, loc_92_)
					loc_93_ = 2;
				end
			else
				loc_112_ = loc_105_;
				loc_113_ = loc_93_;
				loc_114_ = loc_104_;
				loc_115_ = loc_103_;
				loc_116_ = loc_102_;
				loc_93_ = 1;
				loc_92_ = loc_117_;
			end
			loc_94_[1] = bit32_or(loc_96_ + 16, 0);
			return loc_93_, loc_92_
		end), "i32,i32->i32")
	end)(module_locals[90], module_locals[111], module_locals[114], module_locals[156], module_locals[161], module_locals[164], module_locals[3]);
	do (function() --[[spider:chunk]]
	module_locals[41] = { nil };
	module_locals[41][1] = (function(loc_118_)
		return rt_function_type(--[[fn:tok_piece]](function(loc_119_, loc_120_, loc_121_, loc_122_)
			local loc_123_, loc_124_, loc_125_, loc_126_, loc_127_, loc_128_
			if rt_less_than_s32(loc_120_, 0) then
				loc_123_ = loc_122_;
				loc_124_ = loc_119_;
				loc_125_ = loc_118_;
				loc_126_ = loc_121_;
				loc_127_ = loc_120_;
				loc_127_ = 0;
			else
				loc_123_ = loc_122_;
				loc_124_ = loc_119_;
				loc_125_ = loc_118_;
				loc_126_ = loc_121_;
				loc_127_ = loc_120_;
				loc_128_ = buffer_read_i32(loc_125_[1], loc_124_, 0);
				if rt_less_than_s32(loc_127_, loc_128_) then
					loc_124_, loc_127_ = loc_127_, loc_124_;
					loc_128_ = buffer_read_i32(loc_125_[1], loc_127_, 8);
					loc_128_ = rt_load_i32_from_u16(loc_125_, bit32_or(loc_128_ + rt_shift_left_i32(loc_124_, 1), 0), 0);
					rt_store_i32(loc_125_, loc_126_, 0, loc_128_)
					loc_127_ = buffer_read_i32(loc_125_[1], loc_127_, 4);
					loc_124_ = buffer_read_i32(loc_125_[1], bit32_or(loc_127_ + rt_shift_left_i32(loc_124_, 2), 0), 0);
					loc_127_ = 1;
				else
					loc_128_ = loc_124_;
					loc_127_ = 0;
					loc_124_ = loc_128_;
				end
			end
			if not (rt_not_equal_i32(loc_127_, 0)) then
				rt_store_i32(loc_125_, loc_126_, 0, 0)
				loc_124_ = 2344;
			end
			return loc_124_, loc_123_
		end), "i32,i32,i32->i32")
	end)(module_locals[3]);
	module_locals[42] = { nil };
	module_locals[43] = { nil };
	module_locals[137] = { nil };
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[42][1] = (function(loc_129_, loc_130_, loc_131_)
		return rt_function_type(--[[fn:tok_encode]](function(loc_132_, loc_133_, loc_134_, loc_135_, loc_136_, loc_137_)
			local loc_138_, loc_139_, loc_140_, loc_141_, loc_142_, loc_143_, loc_144_, loc_145_, loc_146_, loc_147_, loc_148_, loc_149_, loc_150_, loc_151_, loc_152_, loc_153_, loc_154_, loc_155_, loc_156_, loc_157_, loc_158_, loc_159_, loc_160_, loc_161_
			loc_151_ = 0;
			loc_150_ = 0;
			loc_139_ = 0;
			if rt_greater_than_equal_s32(loc_134_, 1) then
				loc_138_ = loc_137_;
				loc_140_ = loc_131_;
				loc_141_ = loc_129_;
				loc_142_ = loc_130_;
				loc_143_ = loc_132_;
				loc_144_ = loc_133_;
				loc_145_ = loc_134_;
				loc_146_ = loc_135_;
				loc_147_ = loc_136_;
				loc_148_ = 0;
				loc_149_ = 0;
				loc_152_ = 0;
				repeat
					rt_yield_budget = rt_yield_budget - 1
					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
					loc_161_ = buffer_read_i32(loc_140_[1], loc_143_, 36);
					if rt_less_than_s32(loc_161_, 1) then
						loc_153_ = loc_151_;
						loc_151_ = loc_161_;
						loc_151_ = 0;
					else
						loc_153_ = loc_151_;
						loc_151_ = loc_161_;
						loc_160_ = loc_144_;
						loc_161_ = loc_152_;
						loc_157_ = buffer_read_i32(loc_140_[1], loc_143_, 48);
						loc_144_ = loc_160_;
						loc_152_ = loc_161_;
						loc_155_ = loc_151_;
						loc_156_ = bit32_or(loc_160_ + loc_161_, 0);
						loc_151_ = -1;
						loc_158_ = 0;
						loc_159_ = 0;
						loc_154_ = 0;
						repeat
							rt_yield_budget = rt_yield_budget - 1
							if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
							loc_161_ = loc_139_;
							loc_139_ = buffer_read_i32(loc_140_[1], bit32_or(loc_157_ + loc_158_, 0), 0);
							if rt_less_than_equal_s32(loc_139_, loc_154_) then
								loc_160_ = loc_159_;
								loc_159_ = loc_158_;
								loc_161_ = loc_155_;
							else
								loc_160_ = loc_159_;
								loc_159_ = loc_158_;
								loc_161_ = loc_155_;
								if not (rt_greater_than_s32(bit32_or(loc_139_ + loc_152_, 0), loc_145_)) then
									loc_158_ = buffer_read_i32(loc_140_[1], loc_143_, 44);
									loc_155_ = buffer_read_i32(loc_140_[1], bit32_or(loc_158_ + loc_159_, 0), 0);
									loc_158_ = loc_138_;
									loc_158_ = loc_142_[1](loc_156_, loc_155_, loc_139_, loc_158_)
									if rt_not_equal_i32(loc_158_, 0) then
										loc_155_ = loc_139_;
										loc_158_, loc_160_ = loc_160_, loc_158_;
									else
										loc_155_ = loc_139_;
										loc_158_, loc_160_ = loc_160_, loc_158_;
										loc_154_ = loc_155_;
									end
									if rt_not_equal_i32(loc_160_, 0) then
										loc_160_ = loc_158_;
									else
										loc_155_ = loc_151_;
										loc_160_ = loc_158_;
										loc_151_ = loc_158_;
									end
								end
							end
							loc_155_ = loc_161_;
							loc_158_ = bit32_or(loc_159_ + 4, 0);
							loc_160_ = bit32_or(loc_160_ + 1, 0);
							loc_159_ = loc_160_;
						until not (rt_not_equal_i32(loc_161_, loc_160_))
						if rt_less_than_equal_s32(loc_151_, -1) then
							loc_151_ = 0;
						else
							loc_155_ = loc_139_;
							loc_155_ = loc_138_;
							loc_155_ = loc_141_[1](loc_143_, bit32_or(loc_144_ + loc_148_, 0), bit32_or(loc_152_ - loc_148_, 0), bit32_or(loc_146_ + rt_shift_left_i32(loc_149_, 2), 0), bit32_or(loc_147_ - loc_149_, 0), loc_155_)
							loc_139_ = -1;
							if rt_less_than_s32(loc_155_, 0) then
								loc_150_, loc_155_ = loc_155_, loc_150_;
								loc_155_, loc_154_ = loc_154_, loc_155_;
								loc_154_, loc_153_ = loc_153_, loc_154_;
								loc_151_ = 2;
								loc_153_ = 0;
								loc_150_ = 1;
							else
								loc_150_, loc_155_ = loc_155_, loc_150_;
								loc_155_, loc_154_ = loc_154_, loc_155_;
								loc_154_, loc_153_ = loc_153_, loc_154_;
								loc_150_ = bit32_or(loc_150_ + loc_149_, 0);
								if rt_greater_than_equal_s32(loc_150_, loc_147_) then
									loc_150_, loc_155_ = loc_155_, loc_150_;
									loc_155_, loc_154_ = loc_154_, loc_155_;
									loc_154_, loc_153_ = loc_153_, loc_154_;
									loc_153_, loc_151_ = loc_151_, loc_153_;
									loc_151_ = 2;
									loc_153_ = 0;
									loc_150_ = 1;
								else
									loc_148_, loc_149_ = loc_149_, loc_148_;
									loc_149_, loc_151_ = loc_151_, loc_149_;
									loc_150_, loc_153_ = loc_153_, loc_150_;
									loc_153_, loc_154_ = loc_154_, loc_153_;
									loc_154_, loc_155_ = loc_155_, loc_154_;
									loc_151_ = buffer_read_i32(loc_140_[1], loc_143_, 40);
									loc_151_ = buffer_read_i32(loc_140_[1], bit32_or(loc_151_ + rt_shift_left_i32(loc_149_, 2), 0), 0);
									rt_store_i32(loc_140_, bit32_or(loc_146_ + rt_shift_left_i32(loc_155_, 2), 0), 0, loc_151_)
									loc_151_ = 1;
									loc_152_ = bit32_or(loc_154_ + loc_152_, 0);
									loc_148_ = loc_152_;
									loc_149_ = bit32_or(loc_155_ + 1, 0);
								end
							end
						end
					end
					if (loc_151_) >= 0 and (loc_151_) < 2 then
						if (loc_151_) < 1 then
							loc_151_ = 0;
							loc_152_ = bit32_or(loc_152_ + 1, 0);
						else
							loc_151_ = 0;
						end
					else
						loc_151_ = 1;
					end
					if not (rt_not_equal_i32(loc_151_, 0)) then
						loc_151_ = loc_150_;
						if rt_less_than_s32(loc_152_, loc_145_) then
							loc_153_ = 1;
							loc_150_ = 65535;
						else
							loc_153_ = 0;
							loc_150_ = 0;
						end
					end
					loc_151_ = loc_153_;
				until loc_153_ == 0
				if rt_not_equal_i32(loc_150_, 0) then
					loc_150_ = 1;
				else
					loc_150_ = 0;
				end
			else
				loc_138_ = loc_137_;
				loc_140_ = loc_131_;
				loc_141_ = loc_129_;
				loc_142_ = loc_130_;
				loc_143_ = loc_132_;
				loc_144_ = loc_133_;
				loc_145_ = loc_134_;
				loc_146_ = loc_135_;
				loc_147_ = loc_136_;
				loc_160_ = loc_150_;
				loc_161_ = loc_151_;
				loc_150_ = 0;
				loc_148_ = 0;
				loc_149_ = 0;
			end
			if not (rt_not_equal_i32(loc_150_, 0)) then
				loc_139_ = loc_138_;
				loc_148_ = loc_141_[1](loc_143_, bit32_or(loc_144_ + loc_148_, 0), bit32_or(loc_145_ - loc_148_, 0), bit32_or(loc_146_ + rt_shift_left_i32(loc_149_, 2), 0), bit32_or(loc_147_ - loc_149_, 0), loc_139_)
				loc_139_ = bit32_or(loc_148_ + loc_149_, 0);
				loc_149_ = -1;
				if not (rt_greater_than_s32(loc_148_, -1)) then
					loc_148_ = loc_139_;
					loc_139_ = loc_149_;
				end
			end
			return loc_139_, loc_138_
		end), "i32,i32,i32,i32,i32->i32")
	end)(module_locals[43], module_locals[137], module_locals[3]);
	module_locals[159] = { nil };
	end)() end --[[/spider:chunk]]
	module_locals[43][1] = (function(loc_162_, loc_163_, loc_164_)
		return rt_function_type(--[[fn:encode_plain]](function(loc_165_, loc_166_, loc_167_, loc_168_, loc_169_, loc_170_)
			local loc_171_, loc_172_, loc_173_, loc_174_, loc_175_, loc_176_, loc_177_, loc_178_, loc_179_, loc_180_, loc_181_, loc_182_, loc_183_, loc_184_, loc_185_, loc_186_, loc_187_, loc_188_, loc_189_, loc_190_, loc_191_, loc_192_, loc_193_, loc_194_, loc_195_, loc_196_, loc_197_, loc_198_, loc_199_, loc_200_, loc_201_, loc_202_, loc_203_, loc_204_, loc_205_
			loc_204_ = rt_shift_left_i32(loc_167_, 2);
			loc_173_ = loc_164_;
			loc_205_ = loc_170_;
			loc_201_ = loc_162_[1](bit32_or(loc_204_ + 4, 0), loc_205_)
			loc_187_ = loc_162_[1](bit32_or(loc_204_ + 8, 0), loc_205_)
			loc_180_ = 0;
			loc_179_ = 0;
			loc_188_ = 0;
			loc_178_ = 0;
			loc_189_ = 0;
			loc_200_ = 0;
			loc_194_ = 0;
			loc_195_ = 0;
			loc_196_ = 0;
			if rt_greater_than_equal_s32(loc_167_, 1) then
				loc_175_ = loc_163_;
				loc_177_ = loc_162_;
				loc_182_ = loc_166_;
				loc_183_ = loc_168_;
				loc_184_ = loc_169_;
				loc_202_ = loc_167_;
				loc_205_ = loc_165_;
				loc_185_ = 0;
				loc_204_ = loc_201_;
				loc_174_ = loc_187_;
				loc_203_ = 0;
				repeat
					rt_yield_budget = rt_yield_budget - 1
					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
					loc_199_ = loc_188_;
					rt_store_i32(loc_173_, loc_187_, 0, loc_185_)
					loc_188_ = bit32_or(loc_182_ + loc_185_, 0);
					loc_199_ = rt_load_i32_from_u8(loc_173_, loc_188_, 0);
					if rt_greater_than_s32(rt_extend_s8_to_i32(loc_199_), -1) then
						loc_197_ = loc_187_;
						loc_198_ = loc_202_;
						loc_202_ = loc_199_;
						loc_199_ = loc_185_;
						loc_193_ = 0;
					else
						loc_193_ = loc_178_;
						loc_197_ = loc_187_;
						loc_198_ = loc_202_;
						loc_202_ = loc_199_;
						loc_199_ = loc_185_;
						loc_193_ = 0;
						loc_178_ = (rt_equal_i32(rt_and_i32(loc_202_, 224), 192) and 1 or 0);
						if rt_equal_i32(loc_178_, 0) then
							if rt_not_equal_i32(rt_and_i32(loc_202_, 240), 224) then
								if rt_not_equal_i32(rt_and_i32(loc_202_, 248), 240) then
									loc_192_ = 1;
								else
									loc_192_ = loc_200_;
									loc_200_ = loc_189_;
									loc_192_ = 0;
									loc_189_ = 3;
									loc_200_ = 7;
								end
							else
								loc_192_ = loc_200_;
								loc_200_ = loc_193_;
								loc_193_ = loc_189_;
								loc_192_ = 0;
								loc_193_ = 1;
								loc_189_ = 2;
								loc_200_ = 15;
							end
						else
							loc_192_ = loc_200_;
							loc_200_ = loc_189_;
							loc_192_ = 0;
							loc_189_ = 1;
							loc_200_ = 31;
						end
						if rt_not_equal_i32(loc_192_, 0) then
							loc_193_ = 0;
						else
							loc_200_ = rt_and_i32(loc_200_, loc_202_);
							rt_store_i32(loc_173_, loc_201_, 0, loc_200_)
							if rt_greater_than_equal_s32(loc_189_, bit32_or(loc_198_ - loc_199_, 0)) then
								loc_193_ = 0;
							else
								loc_192_ = rt_load_i32_from_u8(loc_173_, loc_188_, 1);
								if rt_not_equal_i32(rt_and_i32(loc_192_, 192), 128) then
									loc_193_ = 0;
								else
									loc_200_ = rt_or_i32(rt_and_i32(loc_192_, 63), rt_shift_left_i32(loc_200_, 6));
									rt_store_i32(loc_173_, loc_201_, 0, loc_200_)
									loc_189_ = bit32_or(loc_189_ + 1, 0);
									if rt_not_equal_i32(loc_178_, 0) then
										loc_193_ = 1;
									else
										loc_192_ = loc_178_;
										loc_178_ = rt_load_i32_from_u8(loc_173_, loc_188_, 2);
										if rt_not_equal_i32(rt_and_i32(loc_178_, 192), 128) then
											loc_193_ = 0;
										else
											loc_200_ = rt_or_i32(rt_and_i32(loc_178_, 63), rt_shift_left_i32(loc_200_, 6));
											rt_store_i32(loc_173_, loc_201_, 0, loc_200_)
											if rt_not_equal_i32(loc_193_, 0) then
												loc_193_ = 2;
											else
												loc_188_ = rt_load_i32_from_u8(loc_173_, loc_188_, 3);
												if rt_not_equal_i32(rt_and_i32(loc_188_, 192), 128) then
													loc_193_ = 0;
												else
													rt_store_i32(loc_173_, loc_201_, 0, rt_or_i32(rt_and_i32(loc_188_, 63), rt_shift_left_i32(loc_200_, 6)))
													loc_193_ = 3;
												end
											end
										end
									end
								end
							end
						end
						if (loc_193_) >= 0 and (loc_193_) < 3 then
							if (loc_193_) < 1 then
								loc_193_ = 0;
								loc_202_ = rt_or_i32(loc_202_, 56320);
							elseif (loc_193_) > 1 then
								loc_193_ = 1;
							else
								loc_193_ = 1;
							end
						else
							loc_193_ = 1;
						end
					end
					if not (rt_not_equal_i32(loc_193_, 0)) then
						loc_193_ = loc_189_;
						rt_store_i32(loc_173_, loc_201_, 0, loc_202_)
						loc_189_ = 1;
					end
					loc_202_ = loc_198_;
					loc_199_ = bit32_or(loc_189_ + loc_199_, 0);
					loc_185_ = loc_199_;
					loc_203_ = bit32_or(loc_203_ + 1, 0);
					loc_201_ = bit32_or(loc_201_ + 4, 0);
					loc_187_ = bit32_or(loc_197_ + 4, 0);
				until not (rt_less_than_s32(loc_199_, loc_198_))
				rt_store_i32(loc_173_, loc_187_, 0, loc_202_)
				loc_181_ = loc_205_;
				loc_176_ = loc_204_;
				loc_172_ = 0;
				loc_186_ = loc_203_;
				loc_190_ = bit32_or(loc_203_ + -1, 0);
				loc_191_ = bit32_or(loc_204_ + 4, 0);
				loc_192_ = bit32_or(loc_205_ + 52, 0);
				loc_193_ = 0;
				repeat
					rt_yield_budget = rt_yield_budget - 1
					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
					loc_204_ = loc_193_;
					loc_205_ = rt_shift_left_i32(loc_204_, 2);
					loc_193_ = buffer_read_i32(loc_173_[1], bit32_or(loc_176_ + loc_205_, 0), 0);
					if rt_not_equal_i32(loc_193_, 39) then
						loc_197_ = loc_180_;
						loc_198_ = loc_204_;
						loc_199_ = loc_188_;
						loc_200_ = loc_178_;
						loc_201_ = loc_171_;
						loc_202_ = loc_189_;
						loc_189_ = loc_185_;
						loc_203_ = loc_187_;
						loc_204_ = loc_174_;
						loc_188_ = 0;
					else
						loc_197_ = loc_180_;
						loc_198_ = loc_204_;
						loc_199_ = loc_188_;
						loc_200_ = loc_178_;
						loc_201_ = loc_171_;
						loc_202_ = loc_189_;
						loc_189_ = loc_185_;
						loc_203_ = loc_187_;
						loc_204_ = loc_174_;
						if rt_greater_than_equal_s32(loc_198_, loc_190_) then
							loc_188_ = 0;
						else
							loc_189_, loc_199_ = loc_199_, loc_189_;
							loc_189_ = buffer_read_i32(loc_173_[1], bit32_or(loc_191_ + loc_205_, 0), 0);
							loc_188_ = 0;
							loc_199_ = bit32_or(loc_198_ + 2, 0);
							if not (rt_greater_than_s32(loc_199_, loc_190_)) then
								loc_188_ = buffer_read_i32(loc_173_[1], bit32_or(loc_176_ + rt_shift_left_i32(loc_199_, 2), 0), 0);
							end
							loc_187_ = bit32_or(loc_189_ + -100, 0);
							if rt_greater_than_u32(loc_187_, 16) then
								loc_187_ = 0;
							else
								if rt_not_equal_i32(rt_and_i32(rt_shift_left_i32(1, loc_187_), 98817), 0) then
									loc_187_ = 1;
								else
									loc_187_ = 0;
								end
							end
							if rt_not_equal_i32(loc_187_, 0) then
								loc_188_ = 1;
							else
								if rt_not_equal_i32(rt_and_i32(loc_189_, -5), 114) then
									loc_187_ = 0;
								else
									if rt_equal_i32(loc_188_, 101) then
										loc_187_ = 1;
									else
										loc_187_ = 0;
									end
								end
								if rt_not_equal_i32(loc_187_, 0) then
									loc_188_ = 0;
								else
									if rt_not_equal_i32(loc_189_, 108) then
										loc_188_ = 1;
									else
										if rt_not_equal_i32(loc_188_, 108) then
											loc_188_ = 2;
										else
											loc_188_ = 0;
										end
									end
								end
								if (loc_188_) >= 0 and (loc_188_) < 2 then
									if (loc_188_) < 1 then
										loc_188_ = 1;
										loc_199_ = bit32_or(loc_198_ + 3, 0);
									else
										loc_188_ = 0;
									end
								else
									loc_188_ = 0;
								end
							end
						end
					end
					if not (rt_not_equal_i32(loc_188_, 0)) then
						loc_188_ = bit32_or(loc_198_ + (rt_equal_i32(loc_193_, 32) and 1 or 0), 0);
						if rt_greater_than_s32(loc_188_, loc_190_) then
							loc_188_ = 0;
						else
							loc_187_ = loc_188_;
							loc_200_ = bit32_or(loc_176_ + rt_shift_left_i32(loc_187_, 2), 0);
							loc_203_ = buffer_read_i32(loc_173_[1], loc_200_, 0);
							loc_185_ = 621;
							loc_188_ = 0;
							repeat
								rt_yield_budget = rt_yield_budget - 1
								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
								if rt_greater_than_s32(loc_188_, loc_185_) then
									loc_197_ = loc_179_;
									loc_180_ = 0;
									loc_179_ = 2;
								else
									loc_197_ = loc_179_;
									repeat
										rt_yield_budget = rt_yield_budget - 1
										if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
										loc_189_, loc_202_ = loc_202_, loc_189_;
										loc_202_, loc_197_ = loc_197_, loc_202_;
										loc_189_ = rt_shift_right_u32(bit32_or(loc_185_ + loc_188_, 0), 1);
										loc_202_ = rt_shift_left_i32(loc_189_, 3);
										loc_197_ = buffer_read_i32(loc_173_[1], loc_202_, 2352);
										if rt_greater_than_equal_u32(loc_203_, loc_197_) then
											loc_180_ = 0;
											loc_197_ = 0;
										else
											loc_197_ = loc_185_;
											loc_185_ = bit32_or(loc_189_ + -1, 0);
											if rt_less_than_s32(loc_188_, loc_189_) then
												loc_180_ = 1;
												loc_197_ = 65535;
											else
												loc_180_ = 0;
												loc_197_ = 1;
											end
										end
									until loc_180_ == 0
									if rt_not_equal_i32(loc_197_, 0) then
										loc_180_ = 0;
										loc_179_ = 0;
									else
										loc_197_ = loc_188_;
										loc_197_ = buffer_read_i32(loc_173_[1], bit32_or(loc_202_ + 2352, 0), 4);
										loc_188_ = bit32_or(loc_189_ + 1, 0);
										if rt_greater_than_u32(loc_203_, loc_197_) then
											loc_180_ = 1;
											loc_179_ = 65535;
										else
											loc_180_ = 0;
											loc_179_ = 1;
										end
									end
								end
								loc_197_ = loc_180_;
							until loc_180_ == 0
							if (loc_179_) >= 0 and (loc_179_) < 2 then
								if (loc_179_) < 1 then
									loc_185_ = 0;
								else
									loc_199_ = loc_187_;
									repeat
										rt_yield_budget = rt_yield_budget - 1
										if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
										loc_197_, loc_203_ = loc_203_, loc_197_;
										loc_203_ = buffer_read_i32(loc_173_[1], bit32_or(loc_176_ + rt_shift_left_i32(loc_199_, 2), 0), 0);
										loc_197_ = loc_179_;
										loc_185_ = 621;
										loc_188_ = 0;
										repeat
											rt_yield_budget = rt_yield_budget - 1
											if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
											if rt_greater_than_s32(loc_188_, loc_185_) then
												loc_180_ = 0;
												loc_197_ = 2;
											else
												repeat
													rt_yield_budget = rt_yield_budget - 1
													if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
													loc_189_, loc_202_ = loc_202_, loc_189_;
													loc_202_, loc_197_ = loc_197_, loc_202_;
													loc_189_ = rt_shift_right_u32(bit32_or(loc_185_ + loc_188_, 0), 1);
													loc_202_ = rt_shift_left_i32(loc_189_, 3);
													loc_197_ = buffer_read_i32(loc_173_[1], loc_202_, 2352);
													if rt_greater_than_equal_u32(loc_203_, loc_197_) then
														loc_180_ = 0;
														loc_197_ = 0;
													else
														loc_197_ = loc_185_;
														loc_185_ = bit32_or(loc_189_ + -1, 0);
														if rt_less_than_s32(loc_188_, loc_189_) then
															loc_180_ = 1;
															loc_197_ = 65535;
														else
															loc_180_ = 0;
															loc_197_ = 1;
														end
													end
												until loc_180_ == 0
												if rt_not_equal_i32(loc_197_, 0) then
													loc_180_ = 0;
													loc_197_ = 1;
												else
													loc_197_ = loc_188_;
													loc_197_ = buffer_read_i32(loc_173_[1], bit32_or(loc_202_ + 2352, 0), 4);
													loc_188_ = bit32_or(loc_189_ + 1, 0);
													if rt_greater_than_u32(loc_203_, loc_197_) then
														loc_180_ = 1;
														loc_197_ = 65535;
													else
														loc_180_ = 0;
														loc_197_ = 0;
													end
												end
											end
										until loc_180_ == 0
										if (loc_197_) >= 0 and (loc_197_) < 2 then
											if (loc_197_) < 1 then
												loc_197_ = loc_189_;
												loc_189_ = (rt_less_than_s32(loc_199_, loc_190_) and 1 or 0);
												loc_199_ = bit32_or(loc_199_ + 1, 0);
												if rt_not_equal_i32(loc_189_, 0) then
													loc_185_ = 1;
													loc_179_ = 65535;
												else
													loc_185_ = 0;
													loc_179_ = 1;
												end
											else
												loc_185_ = 0;
												loc_179_ = 0;
											end
										else
											loc_185_ = 0;
											loc_179_ = 2;
										end
										loc_197_ = loc_185_;
									until loc_185_ == 0
									if (loc_179_) >= 0 and (loc_179_) < 2 then
										if (loc_179_) < 1 then
										else
											loc_186_, loc_199_ = loc_199_, loc_186_;
											loc_186_ = loc_199_;
										end
									else
									end
									if rt_not_equal_i32(loc_199_, loc_198_) then
										loc_185_ = 1;
									else
										loc_185_ = 0;
									end
								end
							else
								loc_185_ = 0;
							end
							if rt_not_equal_i32(loc_185_, 0) then
								loc_185_ = 0;
							else
								loc_203_ = buffer_read_i32(loc_173_[1], loc_200_, 0);
								loc_185_ = 132;
								loc_188_ = 0;
								repeat
									rt_yield_budget = rt_yield_budget - 1
									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
									if rt_greater_than_s32(loc_188_, loc_185_) then
										loc_197_ = loc_179_;
										loc_180_ = 0;
										loc_179_ = 2;
									else
										loc_197_ = loc_179_;
										repeat
											rt_yield_budget = rt_yield_budget - 1
											if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
											loc_189_, loc_202_ = loc_202_, loc_189_;
											loc_202_, loc_197_ = loc_197_, loc_202_;
											loc_189_ = rt_shift_right_u32(bit32_or(loc_185_ + loc_188_, 0), 1);
											loc_202_ = rt_shift_left_i32(loc_189_, 3);
											loc_197_ = buffer_read_i32(loc_173_[1], loc_202_, 7328);
											if rt_greater_than_equal_u32(loc_203_, loc_197_) then
												loc_180_ = 0;
												loc_197_ = 0;
											else
												loc_197_ = loc_185_;
												loc_185_ = bit32_or(loc_189_ + -1, 0);
												if rt_less_than_s32(loc_188_, loc_189_) then
													loc_180_ = 1;
													loc_197_ = 65535;
												else
													loc_180_ = 0;
													loc_197_ = 1;
												end
											end
										until loc_180_ == 0
										if rt_not_equal_i32(loc_197_, 0) then
											loc_180_ = 0;
											loc_179_ = 0;
										else
											loc_197_ = loc_188_;
											loc_197_ = buffer_read_i32(loc_173_[1], bit32_or(loc_202_ + 7328, 0), 4);
											loc_188_ = bit32_or(loc_189_ + 1, 0);
											if rt_greater_than_u32(loc_203_, loc_197_) then
												loc_180_ = 1;
												loc_179_ = 65535;
											else
												loc_180_ = 0;
												loc_179_ = 1;
											end
										end
									end
									loc_197_ = loc_180_;
								until loc_180_ == 0
								if (loc_179_) >= 0 and (loc_179_) < 2 then
									if (loc_179_) < 1 then
										loc_185_ = 1;
									else
										loc_199_ = loc_187_;
										repeat
											rt_yield_budget = rt_yield_budget - 1
											if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
											loc_197_, loc_203_ = loc_203_, loc_197_;
											loc_203_ = buffer_read_i32(loc_173_[1], bit32_or(loc_176_ + rt_shift_left_i32(loc_199_, 2), 0), 0);
											loc_197_ = loc_179_;
											loc_185_ = 132;
											loc_188_ = 0;
											repeat
												rt_yield_budget = rt_yield_budget - 1
												if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
												if rt_greater_than_s32(loc_188_, loc_185_) then
													loc_180_ = 0;
													loc_197_ = 2;
												else
													repeat
														rt_yield_budget = rt_yield_budget - 1
														if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
														loc_189_, loc_202_ = loc_202_, loc_189_;
														loc_202_, loc_197_ = loc_197_, loc_202_;
														loc_189_ = rt_shift_right_u32(bit32_or(loc_185_ + loc_188_, 0), 1);
														loc_202_ = rt_shift_left_i32(loc_189_, 3);
														loc_197_ = buffer_read_i32(loc_173_[1], loc_202_, 7328);
														if rt_greater_than_equal_u32(loc_203_, loc_197_) then
															loc_180_ = 0;
															loc_197_ = 0;
														else
															loc_197_ = loc_185_;
															loc_185_ = bit32_or(loc_189_ + -1, 0);
															if rt_less_than_s32(loc_188_, loc_189_) then
																loc_180_ = 1;
																loc_197_ = 65535;
															else
																loc_180_ = 0;
																loc_197_ = 1;
															end
														end
													until loc_180_ == 0
													if rt_not_equal_i32(loc_197_, 0) then
														loc_180_ = 0;
														loc_197_ = 1;
													else
														loc_197_ = loc_188_;
														loc_197_ = buffer_read_i32(loc_173_[1], bit32_or(loc_202_ + 7328, 0), 4);
														loc_188_ = bit32_or(loc_189_ + 1, 0);
														if rt_greater_than_u32(loc_203_, loc_197_) then
															loc_180_ = 1;
															loc_197_ = 65535;
														else
															loc_180_ = 0;
															loc_197_ = 0;
														end
													end
												end
											until loc_180_ == 0
											if (loc_197_) >= 0 and (loc_197_) < 2 then
												if (loc_197_) < 1 then
													loc_197_ = loc_189_;
													loc_189_ = (rt_less_than_s32(loc_199_, loc_190_) and 1 or 0);
													loc_199_ = bit32_or(loc_199_ + 1, 0);
													if rt_not_equal_i32(loc_189_, 0) then
														loc_185_ = 1;
														loc_179_ = 65535;
													else
														loc_185_ = 0;
														loc_179_ = 1;
													end
												else
													loc_185_ = 0;
													loc_179_ = 0;
												end
											else
												loc_185_ = 0;
												loc_179_ = 2;
											end
											loc_197_ = loc_185_;
										until loc_185_ == 0
										if (loc_179_) >= 0 and (loc_179_) < 2 then
											if (loc_179_) < 1 then
												loc_185_ = 0;
											else
												loc_186_, loc_199_ = loc_199_, loc_186_;
												loc_185_ = 0;
												loc_186_ = loc_199_;
											end
										else
											loc_185_ = 0;
										end
									end
								else
									loc_185_ = 1;
								end
							end
							if rt_not_equal_i32(loc_185_, 0) then
								loc_185_ = 0;
							else
								if rt_not_equal_i32(loc_199_, loc_198_) then
									loc_185_ = 1;
								else
									loc_185_ = 0;
								end
							end
							if rt_not_equal_i32(loc_185_, 0) then
								loc_188_ = 0;
							else
								loc_189_, loc_203_ = loc_203_, loc_189_;
								loc_189_ = buffer_read_i32(loc_173_[1], loc_200_, 0);
								loc_185_ = 0;
								loc_203_ = 9;
								repeat
									rt_yield_budget = rt_yield_budget - 1
									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
									if rt_greater_than_s32(loc_185_, loc_203_) then
										loc_197_ = loc_179_;
										loc_180_ = 0;
										loc_179_ = 2;
									else
										loc_197_ = loc_179_;
										repeat
											rt_yield_budget = rt_yield_budget - 1
											if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
											loc_188_, loc_202_ = loc_202_, loc_188_;
											loc_202_, loc_197_ = loc_197_, loc_202_;
											loc_188_ = rt_shift_right_u32(bit32_or(loc_203_ + loc_185_, 0), 1);
											loc_202_ = rt_shift_left_i32(loc_188_, 3);
											loc_197_ = buffer_read_i32(loc_173_[1], loc_202_, 8400);
											if rt_greater_than_equal_u32(loc_189_, loc_197_) then
												loc_180_ = 0;
												loc_197_ = 0;
											else
												loc_203_ = bit32_or(loc_188_ + -1, 0);
												if rt_less_than_s32(loc_185_, loc_188_) then
													loc_180_ = 1;
													loc_197_ = 65535;
												else
													loc_180_ = 0;
													loc_197_ = 1;
												end
											end
										until loc_180_ == 0
										if rt_not_equal_i32(loc_197_, 0) then
											loc_180_ = 0;
											loc_179_ = 0;
										else
											loc_197_ = loc_185_;
											loc_197_ = buffer_read_i32(loc_173_[1], bit32_or(loc_202_ + 8400, 0), 4);
											loc_185_ = bit32_or(loc_188_ + 1, 0);
											if rt_greater_than_u32(loc_189_, loc_197_) then
												loc_180_ = 1;
												loc_179_ = 65535;
											else
												loc_180_ = 0;
												loc_179_ = 1;
											end
										end
									end
									loc_197_ = loc_180_;
								until loc_180_ == 0
								if (loc_179_) >= 0 and (loc_179_) < 2 then
									if (loc_179_) < 1 then
										loc_185_ = 0;
									else
										loc_185_ = 1;
									end
								else
									loc_185_ = 0;
								end
								if rt_not_equal_i32(loc_185_, 0) then
									loc_188_ = 3;
								else
									loc_185_ = 0;
									loc_203_ = 621;
									repeat
										rt_yield_budget = rt_yield_budget - 1
										if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
										if rt_greater_than_s32(loc_185_, loc_203_) then
											loc_197_ = loc_179_;
											loc_180_ = 0;
											loc_179_ = 2;
										else
											loc_197_ = loc_179_;
											repeat
												rt_yield_budget = rt_yield_budget - 1
												if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
												loc_188_, loc_202_ = loc_202_, loc_188_;
												loc_202_, loc_197_ = loc_197_, loc_202_;
												loc_188_ = rt_shift_right_u32(bit32_or(loc_203_ + loc_185_, 0), 1);
												loc_202_ = rt_shift_left_i32(loc_188_, 3);
												loc_197_ = buffer_read_i32(loc_173_[1], loc_202_, 2352);
												if rt_greater_than_equal_u32(loc_189_, loc_197_) then
													loc_180_ = 0;
													loc_197_ = 0;
												else
													loc_203_ = bit32_or(loc_188_ + -1, 0);
													if rt_less_than_s32(loc_185_, loc_188_) then
														loc_180_ = 1;
														loc_197_ = 65535;
													else
														loc_180_ = 0;
														loc_197_ = 1;
													end
												end
											until loc_180_ == 0
											if rt_not_equal_i32(loc_197_, 0) then
												loc_180_ = 0;
												loc_179_ = 0;
											else
												loc_197_ = loc_185_;
												loc_197_ = buffer_read_i32(loc_173_[1], bit32_or(loc_202_ + 2352, 0), 4);
												loc_185_ = bit32_or(loc_188_ + 1, 0);
												if rt_greater_than_u32(loc_189_, loc_197_) then
													loc_180_ = 1;
													loc_179_ = 65535;
												else
													loc_180_ = 0;
													loc_179_ = 1;
												end
											end
										end
										loc_197_ = loc_180_;
									until loc_180_ == 0
									if (loc_179_) >= 0 and (loc_179_) < 2 then
										if (loc_179_) < 1 then
											loc_185_ = 0;
										else
											loc_185_ = 1;
										end
									else
										loc_185_ = 0;
									end
									if rt_not_equal_i32(loc_185_, 0) then
										loc_188_ = 2;
									else
										loc_185_ = 0;
										loc_203_ = 132;
										repeat
											rt_yield_budget = rt_yield_budget - 1
											if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
											if rt_greater_than_s32(loc_185_, loc_203_) then
												loc_197_ = loc_179_;
												loc_180_ = 0;
												loc_179_ = 2;
											else
												loc_197_ = loc_179_;
												repeat
													rt_yield_budget = rt_yield_budget - 1
													if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
													loc_188_, loc_202_ = loc_202_, loc_188_;
													loc_202_, loc_197_ = loc_197_, loc_202_;
													loc_188_ = rt_shift_right_u32(bit32_or(loc_203_ + loc_185_, 0), 1);
													loc_202_ = rt_shift_left_i32(loc_188_, 3);
													loc_197_ = buffer_read_i32(loc_173_[1], loc_202_, 7328);
													if rt_greater_than_equal_u32(loc_189_, loc_197_) then
														loc_180_ = 0;
														loc_197_ = 0;
													else
														loc_203_ = bit32_or(loc_188_ + -1, 0);
														if rt_less_than_s32(loc_185_, loc_188_) then
															loc_180_ = 1;
															loc_197_ = 65535;
														else
															loc_180_ = 0;
															loc_197_ = 1;
														end
													end
												until loc_180_ == 0
												if rt_not_equal_i32(loc_197_, 0) then
													loc_180_ = 0;
													loc_179_ = 0;
												else
													loc_197_ = loc_185_;
													loc_197_ = buffer_read_i32(loc_173_[1], bit32_or(loc_202_ + 7328, 0), 4);
													loc_185_ = bit32_or(loc_188_ + 1, 0);
													if rt_greater_than_u32(loc_189_, loc_197_) then
														loc_180_ = 1;
														loc_179_ = 65535;
													else
														loc_180_ = 0;
														loc_179_ = 1;
													end
												end
											end
											loc_197_ = loc_180_;
										until loc_180_ == 0
										if (loc_179_) >= 0 and (loc_179_) < 2 then
											if (loc_179_) < 1 then
												loc_185_ = 0;
											else
												loc_185_ = 1;
											end
										else
											loc_185_ = 0;
										end
										if rt_not_equal_i32(loc_185_, 0) then
											loc_188_ = 1;
										else
											loc_186_, loc_187_ = loc_187_, loc_186_;
											loc_187_, loc_188_ = loc_188_, loc_187_;
											loc_188_, loc_199_ = loc_199_, loc_188_;
											repeat
												rt_yield_budget = rt_yield_budget - 1
												if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
												loc_189_, loc_203_ = loc_203_, loc_189_;
												loc_189_ = buffer_read_i32(loc_173_[1], bit32_or(loc_176_ + rt_shift_left_i32(loc_186_, 2), 0), 0);
												loc_185_ = loc_179_;
												loc_180_ = 0;
												loc_203_ = 9;
												loc_188_ = loc_186_;
												repeat
													rt_yield_budget = rt_yield_budget - 1
													if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
													if rt_greater_than_s32(loc_180_, loc_203_) then
														loc_197_ = loc_185_;
														loc_179_ = 0;
														loc_185_ = 1;
													else
														loc_197_ = loc_185_;
														repeat
															rt_yield_budget = rt_yield_budget - 1
															if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
															loc_187_, loc_202_ = loc_202_, loc_187_;
															loc_202_, loc_197_ = loc_197_, loc_202_;
															loc_187_ = rt_shift_right_u32(bit32_or(loc_203_ + loc_180_, 0), 1);
															loc_202_ = rt_shift_left_i32(loc_187_, 3);
															loc_197_ = buffer_read_i32(loc_173_[1], loc_202_, 8400);
															if rt_greater_than_equal_u32(loc_189_, loc_197_) then
																loc_185_ = 0;
																loc_197_ = 0;
															else
																loc_203_ = bit32_or(loc_187_ + -1, 0);
																if rt_less_than_s32(loc_180_, loc_187_) then
																	loc_185_ = 1;
																	loc_197_ = 65535;
																else
																	loc_185_ = 0;
																	loc_197_ = 1;
																end
															end
														until loc_185_ == 0
														if rt_not_equal_i32(loc_197_, 0) then
															loc_179_ = 0;
															loc_185_ = 0;
														else
															loc_197_ = loc_180_;
															loc_197_ = buffer_read_i32(loc_173_[1], bit32_or(loc_202_ + 8400, 0), 4);
															loc_180_ = bit32_or(loc_187_ + 1, 0);
															if rt_greater_than_u32(loc_189_, loc_197_) then
																loc_179_ = 1;
																loc_185_ = 65535;
															else
																loc_179_ = 0;
																loc_185_ = 2;
															end
														end
													end
													loc_197_ = loc_179_;
												until loc_179_ == 0
												if (loc_185_) >= 0 and (loc_185_) < 2 then
													if (loc_185_) < 1 then
														loc_180_ = loc_185_;
														loc_185_ = loc_197_;
														loc_197_ = 0;
														loc_179_ = loc_180_;
													else
														loc_180_ = loc_185_;
														loc_185_ = loc_197_;
														loc_197_ = 0;
														loc_179_ = loc_180_;
													end
												else
													loc_197_ = 1;
													loc_185_ = 0;
													loc_179_ = 0;
												end
												if not (rt_not_equal_i32(loc_197_, 0)) then
													loc_197_ = loc_203_;
													loc_203_ = loc_185_;
													loc_197_ = loc_179_;
													loc_185_ = 0;
													loc_203_ = 621;
													repeat
														rt_yield_budget = rt_yield_budget - 1
														if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
														if rt_greater_than_s32(loc_185_, loc_203_) then
															loc_180_ = 0;
															loc_197_ = 0;
														else
															repeat
																rt_yield_budget = rt_yield_budget - 1
																if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																loc_187_, loc_202_ = loc_202_, loc_187_;
																loc_202_, loc_197_ = loc_197_, loc_202_;
																loc_187_ = rt_shift_right_u32(bit32_or(loc_203_ + loc_185_, 0), 1);
																loc_202_ = rt_shift_left_i32(loc_187_, 3);
																loc_197_ = buffer_read_i32(loc_173_[1], loc_202_, 2352);
																if rt_greater_than_equal_u32(loc_189_, loc_197_) then
																	loc_180_ = 0;
																	loc_197_ = 0;
																else
																	loc_203_ = bit32_or(loc_187_ + -1, 0);
																	if rt_greater_than_equal_s32(loc_185_, loc_187_) then
																		loc_180_ = 0;
																		loc_197_ = 1;
																	else
																		loc_180_ = 1;
																		loc_197_ = 65535;
																	end
																end
															until loc_180_ == 0
															if rt_not_equal_i32(loc_197_, 0) then
																loc_180_ = 0;
																loc_197_ = 0;
															else
																loc_197_ = loc_185_;
																loc_197_ = buffer_read_i32(loc_173_[1], bit32_or(loc_202_ + 2352, 0), 4);
																loc_185_ = bit32_or(loc_187_ + 1, 0);
																if rt_greater_than_u32(loc_189_, loc_197_) then
																	loc_180_ = 1;
																	loc_197_ = 65535;
																else
																	loc_180_ = 0;
																	loc_197_ = 1;
																end
															end
														end
													until loc_180_ == 0
													if rt_not_equal_i32(loc_197_, 0) then
														loc_185_ = 0;
														loc_179_ = 1;
													else
														loc_185_ = 0;
														loc_203_ = 132;
														repeat
															rt_yield_budget = rt_yield_budget - 1
															if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
															if rt_greater_than_s32(loc_185_, loc_203_) then
																loc_180_ = 0;
																loc_197_ = 0;
															else
																repeat
																	rt_yield_budget = rt_yield_budget - 1
																	if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																	loc_187_, loc_202_ = loc_202_, loc_187_;
																	loc_202_, loc_197_ = loc_197_, loc_202_;
																	loc_187_ = rt_shift_right_u32(bit32_or(loc_203_ + loc_185_, 0), 1);
																	loc_202_ = rt_shift_left_i32(loc_187_, 3);
																	loc_197_ = buffer_read_i32(loc_173_[1], loc_202_, 7328);
																	if rt_greater_than_equal_u32(loc_189_, loc_197_) then
																		loc_180_ = 0;
																		loc_197_ = 0;
																	else
																		loc_203_ = bit32_or(loc_187_ + -1, 0);
																		if rt_greater_than_equal_s32(loc_185_, loc_187_) then
																			loc_180_ = 0;
																			loc_197_ = 1;
																		else
																			loc_180_ = 1;
																			loc_197_ = 65535;
																		end
																	end
																until loc_180_ == 0
																if rt_not_equal_i32(loc_197_, 0) then
																	loc_180_ = 0;
																	loc_197_ = 0;
																else
																	loc_197_ = loc_185_;
																	loc_197_ = buffer_read_i32(loc_173_[1], bit32_or(loc_202_ + 7328, 0), 4);
																	loc_185_ = bit32_or(loc_187_ + 1, 0);
																	if rt_greater_than_u32(loc_189_, loc_197_) then
																		loc_180_ = 1;
																		loc_197_ = 65535;
																	else
																		loc_180_ = 0;
																		loc_197_ = 1;
																	end
																end
															end
														until loc_180_ == 0
														if rt_not_equal_i32(loc_197_, 0) then
															loc_185_ = 0;
															loc_179_ = 2;
														else
															loc_197_ = loc_186_;
															loc_186_ = bit32_or(loc_188_ + 1, 0);
															if rt_less_than_s32(loc_188_, loc_190_) then
																loc_185_ = 1;
																loc_179_ = 65535;
															else
																loc_185_ = 0;
																loc_179_ = 3;
															end
														end
													end
												end
												loc_197_ = loc_185_;
											until loc_185_ == 0
											if (loc_179_) >= 0 and (loc_179_) < 3 then
												if (loc_179_) < 1 then
													loc_187_ = loc_199_;
													loc_199_ = loc_188_;
													loc_188_ = 0;
													loc_186_ = loc_187_;
												elseif (loc_179_) > 1 then
													loc_187_ = loc_199_;
													loc_199_ = loc_188_;
													loc_188_ = 0;
													loc_186_ = loc_187_;
												else
													loc_187_ = loc_199_;
													loc_199_ = loc_188_;
													loc_188_ = 0;
													loc_186_ = loc_187_;
												end
											else
												loc_188_ = 0;
												loc_186_ = loc_199_;
											end
										end
									end
								end
							end
							if (loc_188_) >= 0 and (loc_188_) < 3 then
								if (loc_188_) < 1 then
									if rt_not_equal_i32(loc_199_, loc_198_) then
										loc_188_ = 1;
									else
										loc_188_ = 0;
									end
								elseif (loc_188_) > 1 then
									loc_188_ = 0;
								else
									loc_188_ = 0;
								end
							else
								loc_188_ = 0;
							end
						end
						if not (rt_not_equal_i32(loc_188_, 0)) then
							loc_199_ = loc_186_;
							loc_188_ = 9;
							loc_187_ = 0;
							repeat
								rt_yield_budget = rt_yield_budget - 1
								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
								if rt_less_than_equal_s32(loc_187_, loc_188_) then
									loc_197_ = loc_179_;
									repeat
										rt_yield_budget = rt_yield_budget - 1
										if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
										loc_189_, loc_203_ = loc_203_, loc_189_;
										loc_203_, loc_197_ = loc_197_, loc_203_;
										loc_189_ = rt_shift_right_u32(bit32_or(loc_188_ + loc_187_, 0), 1);
										loc_203_ = rt_shift_left_i32(loc_189_, 3);
										loc_197_ = buffer_read_i32(loc_173_[1], loc_203_, 8400);
										if rt_greater_than_equal_u32(loc_193_, loc_197_) then
											loc_186_ = 0;
											loc_197_ = 0;
										else
											loc_197_ = loc_188_;
											loc_188_ = bit32_or(loc_189_ + -1, 0);
											if rt_less_than_s32(loc_187_, loc_189_) then
												loc_186_ = 1;
												loc_197_ = 65535;
											else
												loc_186_ = 0;
												loc_197_ = 1;
											end
										end
									until loc_186_ == 0
									if rt_not_equal_i32(loc_197_, 0) then
										loc_186_ = 0;
										loc_179_ = 1;
									else
										loc_197_ = loc_187_;
										loc_197_ = buffer_read_i32(loc_173_[1], bit32_or(loc_203_ + 8400, 0), 4);
										loc_187_ = bit32_or(loc_189_ + 1, 0);
										if rt_greater_than_u32(loc_193_, loc_197_) then
											loc_186_ = 1;
											loc_179_ = 65535;
										else
											loc_186_ = 0;
											loc_179_ = 2;
										end
									end
								else
									loc_197_ = loc_179_;
									loc_186_ = 0;
									loc_179_ = 0;
								end
								loc_197_ = loc_186_;
							until loc_186_ == 0
							if (loc_179_) >= 0 and (loc_179_) < 2 then
								if (loc_179_) < 1 then
									loc_193_ = loc_189_;
									loc_186_ = loc_199_;
									loc_199_ = loc_198_;
								else
									loc_193_ = loc_189_;
									loc_186_ = loc_199_;
									loc_199_ = loc_198_;
								end
							else
								if rt_greater_than_s32(loc_198_, loc_190_) then
									loc_193_ = loc_198_;
								else
									loc_193_ = loc_198_;
									loc_193_ = loc_198_;
									repeat
										rt_yield_budget = rt_yield_budget - 1
										if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
										loc_197_, loc_203_ = loc_203_, loc_197_;
										loc_203_ = buffer_read_i32(loc_173_[1], bit32_or(loc_176_ + rt_shift_left_i32(loc_193_, 2), 0), 0);
										loc_197_ = loc_179_;
										loc_188_ = 9;
										loc_187_ = 0;
										repeat
											rt_yield_budget = rt_yield_budget - 1
											if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
											if rt_greater_than_s32(loc_187_, loc_188_) then
												loc_186_ = 0;
												loc_197_ = 2;
											else
												repeat
													rt_yield_budget = rt_yield_budget - 1
													if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
													loc_189_, loc_202_ = loc_202_, loc_189_;
													loc_202_, loc_197_ = loc_197_, loc_202_;
													loc_189_ = rt_shift_right_u32(bit32_or(loc_188_ + loc_187_, 0), 1);
													loc_202_ = rt_shift_left_i32(loc_189_, 3);
													loc_197_ = buffer_read_i32(loc_173_[1], loc_202_, 8400);
													if rt_greater_than_equal_u32(loc_203_, loc_197_) then
														loc_186_ = 0;
														loc_197_ = 0;
													else
														loc_197_ = loc_188_;
														loc_188_ = bit32_or(loc_189_ + -1, 0);
														if rt_less_than_s32(loc_187_, loc_189_) then
															loc_186_ = 1;
															loc_197_ = 65535;
														else
															loc_186_ = 0;
															loc_197_ = 1;
														end
													end
												until loc_186_ == 0
												if rt_not_equal_i32(loc_197_, 0) then
													loc_186_ = 0;
													loc_197_ = 1;
												else
													loc_197_ = loc_187_;
													loc_197_ = buffer_read_i32(loc_173_[1], bit32_or(loc_202_ + 8400, 0), 4);
													loc_187_ = bit32_or(loc_189_ + 1, 0);
													if rt_greater_than_u32(loc_203_, loc_197_) then
														loc_186_ = 1;
														loc_197_ = 65535;
													else
														loc_186_ = 0;
														loc_197_ = 0;
													end
												end
											end
										until loc_186_ == 0
										if (loc_197_) >= 0 and (loc_197_) < 2 then
											if (loc_197_) < 1 then
												loc_197_ = loc_193_;
												loc_193_ = loc_189_;
												loc_193_ = bit32_or(loc_197_ + 1, 0);
												loc_189_ = (rt_not_equal_i32(loc_190_, loc_197_) and 1 or 0);
												if rt_not_equal_i32(loc_189_, 0) then
													loc_188_ = 1;
													loc_179_ = 65535;
												else
													loc_188_ = 0;
													loc_179_ = 1;
												end
											else
												loc_188_ = 0;
												loc_179_ = 0;
											end
										else
											loc_188_ = 0;
											loc_179_ = 2;
										end
										loc_197_ = loc_188_;
									until loc_188_ == 0
									if (loc_179_) >= 0 and (loc_179_) < 2 then
										if (loc_179_) < 1 then
										else
											loc_193_ = loc_199_;
										end
									else
									end
								end
								loc_186_ = loc_199_;
								loc_199_ = bit32_or(loc_193_ - rt_and_i32((rt_not_equal_i32(loc_193_, loc_199_) and 1 or 0), (rt_greater_than_s32(bit32_or(loc_193_ - loc_198_, 0), 1) and 1 or 0)), 0);
							end
						end
					end
					loc_193_ = bit32_or(loc_198_ + 1, 0);
					if rt_equal_i32(loc_199_, loc_198_) then
						loc_174_ = loc_204_;
						loc_188_ = loc_199_;
					else
						loc_174_ = loc_204_;
						loc_188_ = loc_199_;
						loc_198_ = loc_193_;
						loc_193_ = loc_199_;
					end
					loc_204_ = buffer_read_i32(loc_173_[1], bit32_or(loc_204_ + rt_shift_left_i32(loc_193_, 2), 0), 0);
					loc_205_ = buffer_read_i32(loc_173_[1], bit32_or(loc_174_ + loc_205_, 0), 0);
					loc_185_ = bit32_or(loc_204_ - loc_205_, 0);
					if rt_not_equal_i32(loc_185_, 0) then
						loc_178_ = loc_177_[1](rt_shift_left_i32(loc_185_, 2), loc_201_)
						if rt_greater_than_equal_s32(loc_185_, 1) then
							loc_187_ = 0;
							loc_189_ = rt_and_i32(loc_185_, 3);
							if not (rt_greater_than_u32(bit32_or(loc_205_ - loc_204_, 0), -4)) then
								loc_201_ = loc_188_;
								loc_202_ = loc_187_;
								loc_203_ = loc_185_;
								loc_204_ = loc_182_;
								loc_182_ = loc_204_;
								loc_204_ = bit32_or(loc_204_ + loc_205_, 0);
								loc_185_ = loc_203_;
								loc_187_ = 0;
								loc_188_ = rt_and_i32(loc_203_, 2147483644);
								loc_203_ = loc_178_;
								repeat
									rt_yield_budget = rt_yield_budget - 1
									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
									loc_201_ = loc_188_;
									loc_202_ = bit32_or(loc_204_ + loc_187_, 0);
									loc_200_ = rt_load_i32_from_u8(loc_173_, loc_202_, 0);
									loc_200_ = buffer_read_i32(loc_173_[1], bit32_or(loc_192_ + rt_shift_left_i32(loc_200_, 2), 0), 0);
									rt_store_i32(loc_173_, loc_203_, 0, loc_200_)
									loc_200_ = rt_load_i32_from_u8(loc_173_, bit32_or(loc_202_ + 1, 0), 0);
									loc_200_ = buffer_read_i32(loc_173_[1], bit32_or(loc_192_ + rt_shift_left_i32(loc_200_, 2), 0), 0);
									rt_store_i32(loc_173_, bit32_or(loc_203_ + 4, 0), 0, loc_200_)
									loc_200_ = rt_load_i32_from_u8(loc_173_, bit32_or(loc_202_ + 2, 0), 0);
									loc_200_ = buffer_read_i32(loc_173_[1], bit32_or(loc_192_ + rt_shift_left_i32(loc_200_, 2), 0), 0);
									rt_store_i32(loc_173_, bit32_or(loc_203_ + 8, 0), 0, loc_200_)
									loc_202_ = rt_load_i32_from_u8(loc_173_, bit32_or(loc_202_ + 3, 0), 0);
									loc_202_ = buffer_read_i32(loc_173_[1], bit32_or(loc_192_ + rt_shift_left_i32(loc_202_, 2), 0), 0);
									rt_store_i32(loc_173_, bit32_or(loc_203_ + 12, 0), 0, loc_202_)
									loc_202_ = bit32_or(loc_187_ + 4, 0);
									loc_187_ = loc_202_;
									loc_188_ = loc_201_;
									loc_203_ = bit32_or(loc_203_ + 16, 0);
								until not (rt_not_equal_i32(loc_201_, loc_202_))
							end
							if not (rt_equal_i32(loc_189_, 0)) then
								loc_202_ = loc_182_;
								loc_203_ = loc_187_;
								loc_204_ = loc_205_;
								loc_182_ = loc_202_;
								loc_205_ = bit32_or(loc_178_ + rt_shift_left_i32(loc_203_, 2), 0);
								loc_187_ = loc_203_;
								loc_204_ = bit32_or(loc_202_ + bit32_or(loc_203_ + loc_204_, 0), 0);
								repeat
									rt_yield_budget = rt_yield_budget - 1
									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
									loc_203_ = rt_load_i32_from_u8(loc_173_, loc_204_, 0);
									loc_203_ = buffer_read_i32(loc_173_[1], bit32_or(loc_192_ + rt_shift_left_i32(loc_203_, 2), 0), 0);
									rt_store_i32(loc_173_, loc_205_, 0, loc_203_)
									loc_205_ = bit32_or(loc_205_ + 4, 0);
									loc_204_ = bit32_or(loc_204_ + 1, 0);
									loc_203_ = bit32_or(loc_189_ + -1, 0);
									loc_189_ = loc_203_;
								until loc_203_ == 0
							end
							loc_180_ = 1;
							if not (rt_equal_i32(loc_185_, 1)) then
								loc_205_ = loc_187_;
								loc_171_ = buffer_read_i32(loc_173_[1], loc_181_, 16);
								loc_187_ = buffer_read_i32(loc_173_[1], loc_181_, 32);
								repeat
									rt_yield_budget = rt_yield_budget - 1
									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
									loc_204_ = loc_180_;
									loc_205_ = loc_188_;
									loc_205_ = 2;
									if rt_greater_than_s32(loc_185_, 2) then
										loc_180_ = loc_185_;
										loc_199_ = loc_197_;
										loc_197_ = loc_179_;
										loc_204_ = loc_185_;
									else
										loc_180_ = loc_185_;
										loc_199_ = loc_197_;
										loc_197_ = loc_179_;
										loc_204_ = loc_185_;
										loc_204_ = loc_205_;
									end
									loc_188_ = buffer_read_i32(loc_173_[1], loc_178_, 0);
									loc_179_ = 2147483647;
									loc_205_ = 1;
									loc_200_ = -1;
									repeat
										rt_yield_budget = rt_yield_budget - 1
										if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
										loc_202_ = loc_189_;
										loc_203_ = loc_185_;
										loc_203_ = buffer_read_i32(loc_173_[1], bit32_or(loc_178_ + rt_shift_left_i32(loc_205_, 2), 0), 0);
										loc_201_ = rt_exclusive_or_i32(bit32_or(rt_multiply_i32(loc_203_, 40503) + 990598335, 0), rt_multiply_i32(loc_188_, -1640531535));
										loc_189_ = rt_and_i32(rt_exclusive_or_i32(rt_shift_right_u32(loc_201_, 15), loc_201_), loc_187_);
										loc_201_ = buffer_read_i32(loc_173_[1], bit32_or(loc_171_ + rt_shift_left_i32(loc_189_, 2), 0), 0);
										if rt_not_equal_i32(loc_201_, -1) then
											loc_179_, loc_202_ = loc_202_, loc_179_;
											loc_202_, loc_204_ = loc_204_, loc_202_;
											loc_188_, loc_203_ = loc_203_, loc_188_;
											loc_203_, loc_200_ = loc_200_, loc_203_;
											loc_200_, loc_194_ = loc_194_, loc_200_;
											repeat
												rt_yield_budget = rt_yield_budget - 1
												if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
												if rt_not_equal_i32(loc_201_, loc_194_) then
													loc_185_ = loc_199_;
													loc_199_ = 0;
												else
													loc_185_ = loc_199_;
													loc_199_ = buffer_read_i32(loc_173_[1], loc_181_, 20);
													loc_201_ = rt_shift_left_i32(loc_189_, 2);
													loc_199_ = buffer_read_i32(loc_173_[1], bit32_or(loc_199_ + loc_201_, 0), 0);
													if rt_not_equal_i32(loc_199_, loc_188_) then
														loc_199_ = 0;
													else
														loc_199_ = loc_185_;
														loc_199_ = 1;
														loc_185_ = 0;
														loc_197_ = 0;
													end
												end
												if not (rt_not_equal_i32(loc_199_, 0)) then
													loc_199_ = loc_197_;
													loc_197_ = loc_201_;
													loc_201_ = loc_185_;
													loc_185_ = loc_179_;
													loc_189_ = rt_and_i32(bit32_or(loc_189_ + 1, 0), loc_187_);
													loc_201_ = buffer_read_i32(loc_173_[1], bit32_or(loc_171_ + rt_shift_left_i32(loc_189_, 2), 0), 0);
													loc_179_ = -1;
													if rt_not_equal_i32(loc_201_, -1) then
														loc_185_ = 1;
														loc_197_ = 65535;
													else
														loc_185_ = 0;
														loc_197_ = 1;
													end
												end
												loc_199_ = loc_185_;
											until loc_185_ == 0
											if not (rt_not_equal_i32(loc_197_, 0)) then
												loc_194_ = loc_200_;
												loc_200_ = loc_179_;
												loc_200_ = buffer_read_i32(loc_173_[1], loc_181_, 24);
												loc_179_ = buffer_read_i32(loc_173_[1], bit32_or(loc_200_ + loc_201_, 0), 0);
												loc_200_ = buffer_read_i32(loc_173_[1], loc_181_, 28);
												loc_200_ = buffer_read_i32(loc_173_[1], bit32_or(loc_200_ + loc_201_, 0), 0);
											end
										else
											loc_185_ = loc_202_;
											loc_202_ = loc_204_;
											loc_204_ = loc_179_;
											loc_188_, loc_203_ = loc_203_, loc_188_;
											loc_203_, loc_200_ = loc_200_, loc_203_;
											loc_200_, loc_194_ = loc_194_, loc_200_;
											loc_194_, loc_189_ = loc_189_, loc_194_;
											loc_189_, loc_201_ = loc_201_, loc_189_;
											loc_179_ = -1;
										end
										loc_185_ = rt_and_i32((rt_greater_than_s32(loc_179_, -1) and 1 or 0), (rt_less_than_s32(loc_179_, loc_204_) and 1 or 0));
										if rt_not_equal_i32(loc_185_, 0) then
											loc_194_ = loc_200_;
										else
											loc_194_ = loc_200_;
											loc_201_ = loc_200_;
											loc_200_ = loc_203_;
										end
										if rt_not_equal_i32(loc_185_, 0) then
											loc_189_ = loc_179_;
										else
											loc_189_ = loc_179_;
											loc_203_ = loc_179_;
											loc_179_ = loc_204_;
										end
										loc_203_ = bit32_or(loc_205_ + 1, 0);
										loc_205_ = loc_203_;
										loc_204_ = loc_202_;
									until not (rt_not_equal_i32(loc_203_, loc_202_))
									if rt_less_than_s32(loc_200_, 0) then
										loc_199_ = 0;
										loc_179_ = 1;
									else
										loc_204_ = loc_185_;
										loc_205_ = loc_200_;
										loc_200_ = loc_199_;
										loc_199_ = loc_197_;
										loc_185_ = 0;
										loc_197_ = loc_179_;
										loc_179_ = 0;
										loc_201_ = loc_205_;
										repeat
											rt_yield_budget = rt_yield_budget - 1
											if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
											loc_204_ = loc_195_;
											loc_205_ = loc_189_;
											loc_189_ = buffer_read_i32(loc_173_[1], bit32_or(loc_178_ + rt_shift_left_i32(loc_179_, 2), 0), 0);
											loc_203_ = bit32_or(loc_179_ + 1, 0);
											if rt_greater_than_equal_s32(loc_203_, loc_180_) then
												loc_195_ = loc_185_;
												loc_185_ = loc_179_;
												loc_202_ = loc_180_;
												loc_185_ = 0;
											else
												loc_195_ = loc_185_;
												loc_185_ = loc_179_;
												loc_202_ = loc_180_;
												loc_205_ = loc_188_;
												loc_188_ = buffer_read_i32(loc_173_[1], bit32_or(loc_178_ + rt_shift_left_i32(loc_203_, 2), 0), 0);
												loc_205_ = rt_exclusive_or_i32(bit32_or(rt_multiply_i32(loc_188_, 40503) + 990598335, 0), rt_multiply_i32(loc_189_, -1640531535));
												loc_179_ = rt_and_i32(rt_exclusive_or_i32(rt_shift_right_u32(loc_205_, 15), loc_205_), loc_187_);
												loc_204_ = buffer_read_i32(loc_173_[1], bit32_or(loc_171_ + rt_shift_left_i32(loc_179_, 2), 0), 0);
												loc_180_ = -1;
												if not (rt_equal_i32(loc_204_, -1)) then
													repeat
														rt_yield_budget = rt_yield_budget - 1
														if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
														if rt_not_equal_i32(loc_204_, loc_189_) then
															loc_205_ = loc_200_;
															loc_200_ = 0;
														else
															loc_205_ = loc_200_;
															loc_200_ = buffer_read_i32(loc_173_[1], loc_181_, 20);
															loc_204_ = rt_shift_left_i32(loc_179_, 2);
															loc_200_ = buffer_read_i32(loc_173_[1], bit32_or(loc_200_ + loc_204_, 0), 0);
															if rt_not_equal_i32(loc_200_, loc_188_) then
																loc_200_ = 0;
															else
																loc_200_ = loc_199_;
																loc_200_ = 1;
																loc_205_ = 0;
																loc_199_ = 0;
															end
														end
														if not (rt_not_equal_i32(loc_200_, 0)) then
															loc_200_ = loc_180_;
															loc_199_, loc_204_ = loc_204_, loc_199_;
															loc_179_ = rt_and_i32(bit32_or(loc_179_ + 1, 0), loc_187_);
															loc_204_ = buffer_read_i32(loc_173_[1], bit32_or(loc_171_ + rt_shift_left_i32(loc_179_, 2), 0), 0);
															loc_180_ = -1;
															if rt_not_equal_i32(loc_204_, -1) then
																loc_205_ = 1;
																loc_199_ = 65535;
															else
																loc_205_ = 0;
																loc_199_ = 1;
															end
														end
														loc_200_ = loc_205_;
													until loc_205_ == 0
													if not (rt_not_equal_i32(loc_199_, 0)) then
														loc_180_, loc_196_ = loc_196_, loc_180_;
														loc_196_ = buffer_read_i32(loc_173_[1], loc_181_, 24);
														loc_180_ = buffer_read_i32(loc_173_[1], bit32_or(loc_196_ + loc_204_, 0), 0);
														loc_196_ = buffer_read_i32(loc_173_[1], loc_181_, 28);
														loc_196_ = buffer_read_i32(loc_173_[1], bit32_or(loc_196_ + loc_204_, 0), 0);
													end
												end
												if rt_not_equal_i32(loc_180_, loc_197_) then
													loc_185_ = 0;
												else
													if rt_not_equal_i32(loc_196_, loc_201_) then
														loc_185_ = 0;
													else
														loc_185_, loc_196_ = loc_196_, loc_185_;
														loc_196_, loc_201_ = loc_201_, loc_196_;
														loc_201_, loc_203_ = loc_203_, loc_201_;
														rt_store_i32(loc_173_, bit32_or(loc_178_ + rt_shift_left_i32(loc_195_, 2), 0), 0, loc_196_)
														loc_185_ = 1;
														loc_203_ = bit32_or(loc_203_ + 2, 0);
														loc_201_ = loc_196_;
													end
												end
											end
											if not (rt_not_equal_i32(loc_185_, 0)) then
												rt_store_i32(loc_173_, bit32_or(loc_178_ + rt_shift_left_i32(loc_195_, 2), 0), 0, loc_189_)
											end
											loc_185_ = bit32_or(loc_195_ + 1, 0);
											loc_179_ = loc_203_;
											loc_180_ = loc_202_;
										until not (rt_less_than_s32(loc_203_, loc_202_))
										if rt_not_equal_i32(loc_195_, 0) then
											loc_199_ = 1;
											loc_179_ = 65535;
										else
											loc_199_ = 0;
											loc_179_ = 0;
										end
									end
									loc_197_ = loc_199_;
								until loc_199_ == 0
								if not (rt_not_equal_i32(loc_179_, 0)) then
									loc_180_ = 1;
								end
							end
						else
							loc_201_ = loc_205_;
							loc_205_ = loc_185_;
							loc_185_ = loc_205_;
							loc_187_ = loc_203_;
							loc_189_ = loc_202_;
							loc_180_ = loc_205_;
						end
						if rt_less_than_equal_s32(loc_180_, bit32_or(loc_184_ - loc_172_, 0)) then
							loc_185_ = rt_shift_left_i32(loc_180_, 2);
							if not (rt_equal_i32(loc_185_, 0)) then
								rt_memory_copy(loc_173_, bit32_or(loc_183_ + rt_shift_left_i32(loc_172_, 2), 0), loc_173_, loc_178_, loc_185_)
							end
							loc_175_[1](loc_178_, loc_198_)
							if rt_greater_than_equal_s32(loc_180_, 0) then
								loc_198_ = 0;
							else
								loc_198_ = loc_197_;
								loc_197_ = loc_179_;
								loc_198_ = 1;
								loc_197_ = 0;
								loc_179_ = 1;
							end
						else
							loc_171_ = loc_198_;
							loc_198_ = loc_197_;
							loc_197_ = loc_179_;
							loc_198_ = 1;
							loc_197_ = 0;
							loc_179_ = 0;
						end
					else
						loc_204_, loc_205_ = loc_205_, loc_204_;
						loc_198_ = 0;
						loc_187_ = loc_203_;
						loc_178_ = loc_200_;
						loc_189_ = loc_202_;
						loc_180_ = 0;
						loc_171_ = loc_201_;
					end
					if not (rt_not_equal_i32(loc_198_, 0)) then
						loc_172_ = bit32_or(loc_180_ + loc_172_, 0);
						if rt_less_than_equal_s32(loc_193_, loc_190_) then
							loc_197_ = 1;
							loc_179_ = 65535;
						else
							loc_197_ = 0;
							loc_179_ = 2;
						end
					end
					loc_180_ = loc_197_;
				until loc_197_ == 0
				if (loc_179_) >= 0 and (loc_179_) < 2 then
					if (loc_179_) < 1 then
						loc_179_ = loc_175_;
						loc_175_ = loc_179_;
						loc_179_[1](loc_178_, loc_171_)
						loc_178_ = 0;
					else
						loc_178_ = 0;
					end
				else
					loc_178_ = 1;
				end
				if not (rt_not_equal_i32(loc_178_, 0)) then
					loc_172_ = -1;
				end
			else
				loc_175_ = loc_163_;
				loc_177_ = loc_162_;
				loc_191_ = loc_196_;
				loc_192_ = loc_195_;
				loc_193_ = loc_194_;
				loc_194_ = loc_200_;
				loc_195_ = loc_189_;
				loc_196_ = loc_178_;
				loc_197_ = loc_188_;
				loc_198_ = loc_169_;
				loc_199_ = loc_168_;
				loc_200_ = loc_167_;
				loc_202_ = loc_166_;
				loc_203_ = loc_165_;
				loc_204_ = loc_179_;
				loc_205_ = loc_180_;
				loc_176_ = loc_201_;
				loc_174_ = loc_187_;
				loc_172_ = 0;
			end
			loc_175_[1](loc_176_, loc_171_)
			loc_175_[1](loc_174_, loc_171_)
			return loc_172_, loc_171_
		end), "i32,i32,i32,i32,i32->i32")
	end)(module_locals[156], module_locals[159], module_locals[3]);
	do (function() --[[spider:chunk]]
	module_locals[44] = { nil };
	module_locals[45] = { nil };
	module_locals[46] = { nil };
	module_locals[115] = { nil };
	module_locals[116] = { nil };
	module_locals[162] = rt_table_new({ }, 14, 14);
	end)() end --[[/spider:chunk]]
	module_locals[44][1] = (function(loc_206_, loc_207_, loc_208_, loc_209_, loc_210_, loc_211_, loc_212_, loc_213_, loc_214_, loc_215_, loc_216_)
		return rt_function_type(--[[fn:model_load]](function(loc_217_, loc_218_, loc_219_, loc_220_)
			local loc_221_, loc_222_, loc_223_, loc_224_, loc_225_, loc_226_, loc_227_, loc_228_, loc_229_, loc_230_, loc_231_, loc_232_, loc_233_, loc_234_, loc_235_, loc_236_, loc_237_, loc_238_, loc_239_, loc_240_, loc_241_, loc_242_, loc_243_, loc_244_, loc_245_, loc_246_, loc_247_
			loc_247_ = loc_214_[1];
			loc_223_ = loc_214_;
			loc_226_ = bit32_or(loc_247_ - 16, 0);
			loc_223_[1] = loc_226_;
			loc_245_ = 0;
			if rt_equal_i32(208, 0) then
				loc_224_ = loc_215_;
				loc_225_ = loc_216_;
				loc_227_ = loc_206_;
				loc_228_ = loc_207_;
				loc_229_ = loc_208_;
				loc_230_ = loc_209_;
				loc_231_ = loc_210_;
				loc_232_ = loc_211_;
				loc_233_ = loc_212_;
				loc_234_ = loc_213_;
				loc_235_ = loc_217_;
				loc_243_ = loc_219_;
				loc_246_ = loc_218_;
				loc_247_ = loc_220_;
			else
				loc_224_ = loc_215_;
				loc_225_ = loc_216_;
				loc_227_ = loc_206_;
				loc_228_ = loc_207_;
				loc_229_ = loc_208_;
				loc_230_ = loc_209_;
				loc_231_ = loc_210_;
				loc_232_ = loc_211_;
				loc_233_ = loc_212_;
				loc_234_ = loc_213_;
				loc_235_ = loc_217_;
				loc_243_ = loc_219_;
				loc_246_ = loc_218_;
				loc_247_ = loc_220_;
				rt_memory_fill(loc_225_, loc_235_, 0, 208)
			end
			loc_246_ = loc_230_[1](loc_246_, 1226, loc_247_)
			if rt_not_equal_i32(loc_246_, 0) then
				loc_244_ = loc_232_[1](loc_246_, 0, 2, loc_247_)
				loc_237_ = loc_233_[1](loc_246_, loc_247_)
				loc_244_ = loc_232_[1](loc_246_, 0, 0, loc_247_)
				loc_244_ = 2;
				if rt_greater_than_s32(loc_237_, 255) then
					loc_244_ = loc_234_[1](loc_237_, loc_247_)
					rt_store_i32(loc_225_, loc_235_, 196, loc_244_)
					if rt_not_equal_i32(loc_244_, 0) then
						rt_store_i32(loc_225_, loc_235_, 200, loc_237_)
						loc_244_ = 0;
						repeat
							rt_yield_budget = rt_yield_budget - 1
							if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
							loc_245_ = buffer_read_i32(loc_225_[1], loc_235_, 196);
							loc_241_ = bit32_or(loc_245_ + loc_244_, 0);
							loc_242_ = 1;
							loc_245_ = bit32_or(loc_237_ - loc_244_, 0);
							loc_240_ = 4194304;
							if not (rt_less_than_s32(loc_245_, 4194304)) then
								loc_245_ = loc_240_;
							end
							loc_245_ = loc_231_[1](loc_241_, loc_242_, loc_245_, loc_246_, loc_247_)
							if rt_not_equal_i32(loc_245_, 0) then
								loc_244_ = bit32_or(loc_245_ + loc_244_, 0);
								if not (rt_equal_i32(loc_243_, 0)) then
									loc_245_ = rt_table_get_function(loc_224_, loc_243_, "i32,i32->");
									loc_245_(loc_244_, loc_237_, loc_247_)
								end
								if rt_less_than_s32(loc_244_, loc_237_) then
									loc_242_ = 1;
									loc_245_ = 65535;
								else
									loc_242_ = 0;
									loc_245_ = 1;
								end
							else
								loc_242_ = 0;
								loc_245_ = 0;
							end
						until loc_242_ == 0
						if rt_not_equal_i32(loc_245_, 0) then
							loc_247_ = loc_229_[1](loc_246_, loc_247_)
							loc_236_ = buffer_read_i32(loc_225_[1], loc_235_, 196);
							loc_247_ = buffer_read_i32(loc_225_[1], loc_236_, 0);
							if rt_equal_i32(loc_247_, 1634415666) then
								loc_247_ = buffer_read_i32(loc_225_[1], loc_236_, 4);
								loc_222_ = 2;
								if not (rt_not_equal_i32(loc_247_, 2)) then
									loc_247_ = loc_236_;
									loc_236_ = buffer_read_i32(loc_225_[1], loc_247_, 8);
									rt_store_i32(loc_225_, loc_235_, 0, loc_236_)
									loc_240_ = buffer_read_i32(loc_225_[1], loc_247_, 12);
									rt_store_i32(loc_225_, loc_235_, 4, loc_240_)
									loc_241_ = buffer_read_i32(loc_225_[1], loc_247_, 16);
									rt_store_i32(loc_225_, loc_235_, 8, loc_241_)
									loc_242_ = buffer_read_i32(loc_225_[1], loc_247_, 20);
									rt_store_i32(loc_225_, loc_235_, 12, loc_242_)
									loc_246_ = buffer_read_i32(loc_225_[1], loc_247_, 24);
									rt_store_i32(loc_225_, loc_235_, 16, loc_246_)
									loc_243_ = buffer_read_i32(loc_225_[1], loc_247_, 28);
									rt_store_i32(loc_225_, loc_235_, 20, loc_243_)
									loc_246_ = buffer_read_i32(loc_225_[1], loc_247_, 32);
									rt_store_i32(loc_225_, loc_235_, 24, loc_246_)
									loc_244_ = rt_load_i32_from_u8(loc_225_, loc_247_, 36);
									loc_239_ = buffer_read_i32(loc_225_[1], loc_247_, 37);
									rt_store_i32(loc_225_, loc_235_, 204, loc_239_)
									if rt_less_than_s32(loc_239_, 1) then
										loc_238_ = loc_237_;
										loc_237_ = loc_235_;
										loc_235_ = loc_247_;
									else
										loc_238_ = loc_237_;
										loc_237_ = loc_235_;
										loc_235_ = loc_247_;
										loc_247_ = rt_remainder_s32(loc_236_, loc_239_);
										loc_246_ = loc_247_;
										if rt_not_equal_i32(loc_247_, 0) then
											loc_235_, loc_244_ = loc_244_, loc_235_;
											loc_244_, loc_237_ = loc_237_, loc_244_;
											loc_237_, loc_242_ = loc_242_, loc_237_;
											loc_236_, loc_243_ = loc_243_, loc_236_;
											loc_238_, loc_241_ = loc_241_, loc_238_;
											loc_239_, loc_240_ = loc_240_, loc_239_;
										else
											loc_235_, loc_244_ = loc_244_, loc_235_;
											loc_244_, loc_237_ = loc_237_, loc_244_;
											loc_237_, loc_242_ = loc_242_, loc_237_;
											loc_236_, loc_243_ = loc_243_, loc_236_;
											loc_238_, loc_241_ = loc_241_, loc_238_;
											loc_239_, loc_240_ = loc_240_, loc_239_;
											loc_247_ = rt_remainder_s32(loc_239_, loc_240_);
											loc_246_ = loc_247_;
											if rt_not_equal_i32(loc_247_, 0) then
												loc_239_ = loc_238_;
												loc_238_ = loc_237_;
												loc_237_ = loc_236_;
												loc_236_ = loc_235_;
											else
												loc_239_ = loc_238_;
												loc_238_ = loc_237_;
												loc_246_ = loc_222_;
												loc_247_ = loc_236_;
												loc_236_ = loc_235_;
												loc_237_ = rt_divide_s32(loc_243_, loc_238_);
												loc_245_ = bit32_or(loc_242_ + 256, 0);
												rt_store_i32(loc_225_, loc_244_, 32, loc_245_)
												loc_246_ = rt_shift_left_i32(loc_243_, 2);
												loc_242_ = rt_multiply_i32(loc_246_, loc_239_);
												loc_245_ = bit32_or(loc_245_ + loc_242_, 0);
												rt_store_i32(loc_225_, loc_244_, 36, loc_245_)
												loc_245_ = bit32_or(loc_245_ + loc_242_, 0);
												rt_store_i32(loc_225_, loc_244_, 40, loc_245_)
												loc_242_ = loc_221_;
												loc_221_ = loc_234_[1](8, loc_242_)
												loc_235_ = rt_multiply_i32(loc_247_, loc_243_);
												loc_222_ = rt_divide_s32(loc_235_, loc_240_);
												loc_247_ = loc_222_;
												loc_247_ = loc_237_;
												loc_245_ = bit32_or(loc_245_ + loc_246_, 0);
												loc_235_ = bit32_or(loc_245_ + loc_235_, 0);
												rt_store_i32(loc_225_, loc_221_, 4, loc_235_)
												rt_store_i32(loc_225_, loc_221_, 0, loc_245_)
												rt_store_i32(loc_225_, loc_244_, 28, loc_221_)
												rt_store_i32(loc_225_, loc_226_, 12, bit32_or(loc_235_ + rt_shift_left_i32(loc_222_, 2), 0))
												loc_242_ = loc_227_[1](bit32_or(loc_226_ + 12, 0), loc_239_, rt_multiply_i32(rt_multiply_i32(loc_238_, loc_243_), loc_237_), loc_240_, loc_242_)
												rt_store_i32(loc_225_, loc_244_, 44, loc_242_)
												loc_238_ = buffer_read_i32(loc_225_[1], loc_244_, 8);
												loc_239_ = buffer_read_i32(loc_225_[1], loc_244_, 0);
												loc_240_ = buffer_read_i32(loc_225_[1], loc_244_, 16);
												loc_242_ = buffer_read_i32(loc_225_[1], loc_244_, 204);
												loc_242_ = loc_227_[1](bit32_or(loc_226_ + 12, 0), loc_238_, rt_multiply_i32(rt_multiply_i32(loc_239_, loc_237_), loc_240_), loc_242_, loc_243_)
												rt_store_i32(loc_225_, loc_244_, 48, loc_242_)
												loc_238_ = buffer_read_i32(loc_225_[1], loc_244_, 8);
												loc_239_ = buffer_read_i32(loc_225_[1], loc_244_, 0);
												loc_240_ = buffer_read_i32(loc_225_[1], loc_244_, 16);
												loc_242_ = buffer_read_i32(loc_225_[1], loc_244_, 204);
												loc_242_ = loc_227_[1](bit32_or(loc_226_ + 12, 0), loc_238_, rt_multiply_i32(rt_multiply_i32(loc_239_, loc_237_), loc_240_), loc_242_, loc_243_)
												rt_store_i32(loc_225_, loc_244_, 52, loc_242_)
												loc_238_ = buffer_read_i32(loc_225_[1], loc_244_, 8);
												loc_239_ = buffer_read_i32(loc_225_[1], loc_244_, 12);
												loc_240_ = buffer_read_i32(loc_225_[1], loc_244_, 0);
												loc_242_ = buffer_read_i32(loc_225_[1], loc_244_, 204);
												loc_242_ = loc_227_[1](bit32_or(loc_226_ + 12, 0), loc_238_, rt_multiply_i32(rt_multiply_i32(loc_239_, loc_237_), loc_240_), loc_242_, loc_243_)
												rt_store_i32(loc_225_, loc_244_, 56, loc_242_)
												loc_238_ = buffer_read_i32(loc_225_[1], loc_244_, 8);
												loc_239_ = buffer_read_i32(loc_225_[1], loc_244_, 4);
												loc_240_ = buffer_read_i32(loc_225_[1], loc_244_, 0);
												loc_242_ = buffer_read_i32(loc_225_[1], loc_244_, 204);
												loc_242_ = loc_227_[1](bit32_or(loc_226_ + 12, 0), loc_238_, rt_multiply_i32(loc_239_, loc_240_), loc_242_, loc_243_)
												rt_store_i32(loc_225_, loc_244_, 60, loc_242_)
												loc_238_ = buffer_read_i32(loc_225_[1], loc_244_, 8);
												loc_239_ = buffer_read_i32(loc_225_[1], loc_244_, 0);
												loc_240_ = buffer_read_i32(loc_225_[1], loc_244_, 4);
												loc_242_ = buffer_read_i32(loc_225_[1], loc_244_, 204);
												loc_242_ = loc_227_[1](bit32_or(loc_226_ + 12, 0), loc_238_, rt_multiply_i32(loc_239_, loc_240_), loc_242_, loc_243_)
												rt_store_i32(loc_225_, loc_244_, 64, loc_242_)
												loc_238_ = buffer_read_i32(loc_225_[1], loc_244_, 8);
												loc_239_ = buffer_read_i32(loc_225_[1], loc_244_, 4);
												loc_240_ = buffer_read_i32(loc_225_[1], loc_244_, 0);
												loc_242_ = buffer_read_i32(loc_225_[1], loc_244_, 204);
												loc_242_ = loc_227_[1](bit32_or(loc_226_ + 12, 0), loc_238_, rt_multiply_i32(loc_239_, loc_240_), loc_242_, loc_243_)
												rt_store_i32(loc_225_, loc_244_, 68, loc_242_)
												if rt_equal_i32(rt_and_i32(loc_236_, 255), 0) then
													loc_242_ = loc_241_;
													loc_241_ = loc_234_;
													loc_234_ = loc_241_;
													loc_239_ = buffer_read_i32(loc_225_[1], loc_244_, 204);
													loc_238_ = buffer_read_i32(loc_225_[1], loc_244_, 20);
													loc_240_ = buffer_read_i32(loc_225_[1], loc_244_, 0);
													loc_243_ = loc_241_[1](8, loc_243_)
													loc_241_ = buffer_read_i32(loc_225_[1], loc_226_, 12);
													rt_store_i32(loc_225_, loc_243_, 0, loc_241_)
													loc_240_ = rt_multiply_i32(loc_238_, loc_240_);
													loc_241_ = bit32_or(loc_241_ + loc_240_, 0);
													rt_store_i32(loc_225_, loc_243_, 4, loc_241_)
													loc_240_ = rt_divide_s32(loc_240_, loc_239_);
													loc_241_ = bit32_or(loc_241_ + rt_shift_left_i32(loc_240_, 2), 0);
												else
													loc_240_ = loc_243_;
													loc_242_ = loc_241_;
													loc_241_ = loc_234_;
													loc_234_ = loc_241_;
													loc_243_ = buffer_read_i32(loc_225_[1], loc_244_, 28);
													loc_241_ = buffer_read_i32(loc_225_[1], loc_226_, 12);
													loc_221_ = loc_240_;
												end
												rt_store_i32(loc_225_, loc_244_, 72, loc_243_)
												loc_243_ = buffer_read_i32(loc_225_[1], loc_244_, 196);
												loc_222_ = 2;
												if not (rt_greater_than_s32(bit32_or(loc_241_ - loc_243_, 0), loc_242_)) then
													loc_242_ = loc_228_;
													loc_243_ = loc_222_;
													loc_228_ = loc_242_;
													loc_243_ = loc_221_;
													loc_222_ = loc_242_[1](loc_244_, loc_243_)
												end
											end
										end
									end
								end
							else
								loc_245_ = loc_237_;
								loc_246_ = loc_236_;
								loc_247_ = loc_235_;
								loc_222_ = 2;
							end
						else
							loc_243_ = loc_237_;
							loc_244_ = loc_235_;
							loc_245_ = loc_229_;
							loc_229_ = loc_245_;
							loc_247_ = loc_245_[1](loc_246_, loc_247_)
							loc_222_ = 4;
						end
					else
						loc_241_ = loc_237_;
						loc_242_ = loc_243_;
						loc_243_ = loc_235_;
						loc_244_ = loc_245_;
						loc_245_ = loc_229_;
						loc_229_ = loc_245_;
						loc_247_ = loc_245_[1](loc_246_, loc_247_)
						loc_222_ = 3;
					end
				else
					loc_240_ = loc_237_;
					loc_241_ = loc_243_;
					loc_242_ = loc_235_;
					loc_243_ = loc_245_;
					loc_245_ = loc_229_;
					loc_229_ = loc_245_;
					loc_247_ = loc_245_[1](loc_246_, loc_247_)
					loc_222_ = loc_244_;
				end
			else
				loc_244_ = loc_243_;
				loc_243_ = loc_246_;
				loc_246_ = loc_245_;
				loc_245_ = loc_235_;
				loc_222_ = 1;
				loc_221_ = loc_247_;
			end
			loc_223_[1] = bit32_or(loc_226_ + 16, 0);
			return loc_222_, loc_221_
		end), "i32,i32,i32->i32")
	end)(module_locals[45], module_locals[46], module_locals[90], module_locals[111], module_locals[114], module_locals[115], module_locals[116], module_locals[156], module_locals[164], module_locals[162], module_locals[3]);
	do (function() --[[spider:chunk]]
	module_locals[45][1] = (function(loc_248_, loc_249_)
		return rt_function_type(--[[fn:map_quantized]](function(loc_250_, loc_251_, loc_252_, loc_253_, loc_254_)
			local loc_255_, loc_256_, loc_257_, loc_258_, loc_259_, loc_260_, loc_261_, loc_262_, loc_263_, loc_264_, loc_265_, loc_266_, loc_267_, loc_268_, loc_269_, loc_270_, loc_271_, loc_272_, loc_273_, loc_274_
			loc_257_ = loc_249_;
			loc_274_ = loc_254_;
			loc_256_ = loc_248_[1](rt_shift_left_i32(loc_251_, 3), loc_274_)
			loc_258_ = buffer_read_i32(loc_257_[1], loc_250_, 0);
			if rt_less_than_s32(loc_251_, 1) then
				loc_259_ = loc_250_;
				loc_260_ = loc_248_;
				loc_261_ = loc_251_;
				loc_262_ = loc_252_;
				loc_263_ = loc_253_;
			else
				loc_259_ = loc_250_;
				loc_260_ = loc_248_;
				loc_261_ = loc_251_;
				loc_262_ = loc_252_;
				loc_263_ = loc_253_;
				loc_271_ = rt_divide_s32(loc_262_, loc_263_);
				loc_273_ = rt_shift_left_i32(loc_271_, 2);
				loc_274_ = rt_and_i32(loc_261_, 3);
				loc_272_ = loc_271_;
				if rt_greater_than_equal_u32(loc_261_, 4) then
					loc_272_ = loc_262_;
					loc_261_, loc_274_ = loc_274_, loc_261_;
					loc_265_ = loc_256_;
					loc_263_ = loc_272_;
					loc_262_ = loc_273_;
					loc_264_ = 0;
					loc_268_ = rt_shift_left_i32(loc_271_, 3);
					loc_270_ = rt_multiply_i32(loc_272_, 3);
					loc_266_ = bit32_or(loc_268_ + loc_270_, 0);
					loc_269_ = rt_shift_left_i32(loc_272_, 1);
					loc_267_ = bit32_or(loc_273_ + loc_269_, 0);
					loc_268_ = bit32_or(loc_268_ + loc_269_, 0);
					loc_271_ = rt_multiply_i32(loc_271_, 12);
					loc_269_ = bit32_or(loc_271_ + loc_270_, 0);
					loc_270_ = bit32_or(loc_271_ + rt_shift_left_i32(loc_272_, 2), 0);
					loc_271_ = bit32_or(loc_272_ + loc_273_, 0);
					loc_272_ = rt_and_i32(loc_274_, 2147483644);
					repeat
						rt_yield_budget = rt_yield_budget - 1
						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
						loc_273_ = loc_258_;
						loc_258_ = loc_263_;
						loc_274_ = loc_272_;
						loc_272_ = loc_262_;
						rt_store_i32(loc_257_, loc_265_, 0, loc_273_)
						rt_store_i32(loc_257_, bit32_or(loc_265_ + 28, 0), 0, bit32_or(loc_273_ + loc_270_, 0))
						rt_store_i32(loc_257_, bit32_or(loc_265_ + 24, 0), 0, bit32_or(loc_273_ + loc_269_, 0))
						rt_store_i32(loc_257_, bit32_or(loc_265_ + 20, 0), 0, bit32_or(loc_273_ + loc_266_, 0))
						rt_store_i32(loc_257_, bit32_or(loc_265_ + 16, 0), 0, bit32_or(loc_273_ + loc_268_, 0))
						rt_store_i32(loc_257_, bit32_or(loc_265_ + 12, 0), 0, bit32_or(loc_273_ + loc_267_, 0))
						rt_store_i32(loc_257_, bit32_or(loc_265_ + 8, 0), 0, bit32_or(loc_273_ + loc_271_, 0))
						loc_273_ = bit32_or(loc_273_ + loc_258_, 0);
						rt_store_i32(loc_257_, bit32_or(loc_265_ + 4, 0), 0, loc_273_)
						loc_265_ = bit32_or(loc_265_ + 32, 0);
						loc_263_ = loc_258_;
						loc_262_ = loc_272_;
						loc_258_ = bit32_or(bit32_or(bit32_or(bit32_or(bit32_or(bit32_or(bit32_or(loc_273_ + loc_272_, 0) + loc_258_, 0) + loc_272_, 0) + loc_258_, 0) + loc_272_, 0) + loc_258_, 0) + loc_272_, 0);
						loc_273_ = bit32_or(loc_264_ + 4, 0);
						loc_264_ = loc_273_;
						loc_272_ = loc_274_;
					until not (rt_not_equal_i32(loc_274_, loc_273_))
				else
					loc_272_ = loc_262_;
					loc_261_, loc_274_ = loc_274_, loc_261_;
					loc_263_ = loc_272_;
					loc_262_ = loc_273_;
					loc_264_ = 0;
				end
				if not (rt_equal_i32(loc_261_, 0)) then
					loc_264_ = bit32_or(loc_256_ + rt_shift_left_i32(loc_264_, 3), 0);
					repeat
						rt_yield_budget = rt_yield_budget - 1
						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
						loc_265_ = loc_258_;
						loc_258_ = loc_262_;
						rt_store_i32(loc_257_, loc_264_, 0, loc_265_)
						loc_265_ = bit32_or(loc_265_ + loc_263_, 0);
						rt_store_i32(loc_257_, bit32_or(loc_264_ + 4, 0), 0, loc_265_)
						loc_264_ = bit32_or(loc_264_ + 8, 0);
						loc_262_ = loc_258_;
						loc_258_ = bit32_or(loc_265_ + loc_258_, 0);
						loc_265_ = bit32_or(loc_261_ + -1, 0);
						loc_261_ = loc_265_;
					until loc_265_ == 0
				end
			end
			rt_store_i32(loc_257_, loc_259_, 0, loc_258_)
			return loc_256_, loc_255_
		end), "i32,i32,i32,i32->i32")
	end)(module_locals[156], module_locals[3]);
	end)() end --[[/spider:chunk]]
	module_locals[46][1] = (function(loc_275_, loc_276_, loc_277_, loc_278_, loc_279_)
		return rt_function_type(--[[fn:alloc_state]](function(loc_280_, loc_281_)
			local loc_282_, loc_283_, loc_284_, loc_285_, loc_286_, loc_287_, loc_288_, loc_289_, loc_290_, loc_291_, loc_292_, loc_293_, loc_294_, loc_295_, loc_296_, loc_297_, loc_298_, loc_299_, loc_300_, loc_301_, loc_302_, loc_303_, loc_304_, loc_305_, loc_306_, loc_307_, loc_308_, loc_309_, loc_310_, loc_311_, loc_312_, loc_313_, loc_314_, loc_315_, loc_316_, loc_317_, loc_318_, loc_319_, loc_320_, loc_321_
			loc_318_ = buffer_read_i32(loc_279_[1], loc_280_, 12);
			loc_284_ = loc_279_;
			loc_320_ = buffer_read_i32(loc_284_[1], loc_280_, 16);
			loc_319_ = buffer_read_i32(loc_284_[1], loc_280_, 0);
			loc_321_ = loc_281_;
			loc_291_ = loc_278_[1](loc_319_, 4, loc_321_)
			rt_store_i32(loc_284_, loc_280_, 76, loc_291_)
			loc_292_ = loc_278_[1](loc_319_, 4, loc_321_)
			rt_store_i32(loc_284_, loc_280_, 80, loc_292_)
			loc_293_ = loc_278_[1](loc_319_, 4, loc_321_)
			rt_store_i32(loc_284_, loc_280_, 84, loc_293_)
			loc_316_ = buffer_read_i32(loc_284_[1], loc_280_, 4);
			loc_295_ = loc_278_[1](loc_316_, 4, loc_321_)
			rt_store_i32(loc_284_, loc_280_, 88, loc_295_)
			loc_296_ = loc_278_[1](loc_316_, 4, loc_321_)
			rt_store_i32(loc_284_, loc_280_, 92, loc_296_)
			loc_297_ = loc_278_[1](loc_319_, 1, loc_321_)
			rt_store_i32(loc_284_, loc_280_, 116, loc_297_)
			loc_317_ = buffer_read_i32(loc_284_[1], loc_280_, 204);
			loc_288_ = rt_divide_s32(loc_316_, loc_317_);
			loc_294_ = rt_shift_left_i32(loc_316_, 4);
			loc_299_ = rt_divide_s32(loc_319_, loc_317_);
			loc_302_ = rt_shift_left_i32(loc_319_, 4);
			loc_317_ = rt_divide_s32(rt_multiply_i32(loc_320_, loc_319_), loc_318_);
			loc_320_ = rt_shift_left_i32(loc_317_, 4);
			loc_315_ = loc_299_;
			loc_300_ = loc_278_[1](loc_299_, 4, loc_321_)
			rt_store_i32(loc_284_, loc_280_, 120, loc_300_)
			loc_301_ = loc_278_[1](loc_316_, 1, loc_321_)
			loc_316_ = loc_288_;
			rt_store_i32(loc_284_, loc_280_, 124, loc_301_)
			loc_303_ = loc_278_[1](loc_288_, 4, loc_321_)
			rt_store_i32(loc_284_, loc_280_, 128, loc_303_)
			loc_304_ = loc_278_[1](loc_319_, 4, loc_321_)
			loc_316_ = loc_317_;
			rt_store_i32(loc_284_, loc_280_, 96, loc_304_)
			loc_305_ = loc_278_[1](loc_317_, 4, loc_321_)
			rt_store_i32(loc_284_, loc_280_, 100, loc_305_)
			loc_306_ = loc_278_[1](loc_317_, 4, loc_321_)
			rt_store_i32(loc_284_, loc_280_, 104, loc_306_)
			loc_290_ = buffer_read_i32(loc_284_[1], loc_280_, 24);
			loc_309_ = rt_divide_s32(loc_319_, loc_318_);
			loc_312_ = rt_divide_s32(loc_309_, 2);
			loc_319_ = rt_multiply_i32(loc_290_, loc_312_);
			loc_307_ = loc_278_[1](rt_multiply_i32(loc_318_, loc_290_), 4, loc_321_)
			rt_store_i32(loc_284_, loc_280_, 108, loc_307_)
			loc_318_ = buffer_read_i32(loc_284_[1], loc_280_, 20);
			loc_308_ = loc_278_[1](loc_318_, 4, loc_321_)
			rt_store_i32(loc_284_, loc_280_, 112, loc_308_)
			loc_318_ = buffer_read_i32(loc_284_[1], loc_280_, 8);
			loc_318_ = rt_multiply_i32(rt_multiply_i32(loc_290_, loc_317_), loc_318_);
			loc_310_ = loc_278_[1](loc_318_, 4, loc_321_)
			rt_store_i32(loc_284_, loc_280_, 180, loc_310_)
			loc_311_ = loc_278_[1](loc_318_, 4, loc_321_)
			loc_318_ = loc_309_;
			loc_318_ = loc_312_;
			rt_store_i32(loc_284_, loc_280_, 184, loc_311_)
			loc_313_ = loc_278_[1](loc_319_, 4, loc_321_)
			rt_store_i32(loc_284_, loc_280_, 188, loc_313_)
			loc_314_ = loc_278_[1](loc_319_, 4, loc_321_)
			rt_store_i32(loc_284_, loc_280_, 192, loc_314_)
			loc_289_ = loc_278_[1](loc_302_, 4, loc_321_)
			rt_store_i32(loc_284_, loc_280_, 132, loc_289_)
			loc_315_ = loc_278_[1](loc_302_, 4, loc_321_)
			rt_store_i32(loc_284_, loc_280_, 136, loc_315_)
			loc_316_ = loc_278_[1](loc_302_, 4, loc_321_)
			rt_store_i32(loc_284_, loc_280_, 140, loc_316_)
			loc_317_ = loc_278_[1](loc_302_, 4, loc_321_)
			rt_store_i32(loc_284_, loc_280_, 152, loc_317_)
			loc_318_ = loc_278_[1](loc_320_, 4, loc_321_)
			rt_store_i32(loc_284_, loc_280_, 156, loc_318_)
			loc_298_ = loc_278_[1](loc_320_, 4, loc_321_)
			rt_store_i32(loc_284_, loc_280_, 160, loc_298_)
			loc_319_ = loc_278_[1](loc_294_, 4, loc_321_)
			rt_store_i32(loc_284_, loc_280_, 144, loc_319_)
			loc_320_ = loc_278_[1](loc_294_, 4, loc_321_)
			rt_store_i32(loc_284_, loc_280_, 148, loc_320_)
			loc_321_ = loc_278_[1](loc_302_, 1, loc_321_)
			rt_store_i32(loc_284_, loc_280_, 164, loc_321_)
			loc_299_ = loc_278_[1](rt_shift_left_i32(loc_299_, 4), 4, loc_302_)
			rt_store_i32(loc_284_, loc_280_, 168, loc_299_)
			loc_294_ = loc_278_[1](loc_294_, 1, loc_302_)
			rt_store_i32(loc_284_, loc_280_, 172, loc_294_)
			loc_302_ = loc_278_[1](rt_shift_left_i32(loc_288_, 4), 4, loc_302_)
			rt_store_i32(loc_284_, loc_280_, 176, loc_302_)
			loc_283_ = 3;
			if rt_equal_i32(loc_289_, 0) then
				loc_285_ = loc_275_;
				loc_286_ = loc_276_;
				loc_287_ = loc_277_;
				loc_288_ = loc_278_;
				loc_289_ = loc_280_;
			else
				loc_285_ = loc_275_;
				loc_286_ = loc_276_;
				loc_287_ = loc_277_;
				loc_288_ = loc_278_;
				loc_289_ = loc_280_;
				if rt_equal_i32(loc_315_, 0) then
					loc_315_ = loc_295_;
					loc_295_ = loc_316_;
					loc_316_ = loc_294_;
					loc_294_ = loc_317_;
					loc_317_ = loc_293_;
					loc_293_ = loc_318_;
					loc_318_ = loc_292_;
					loc_292_ = loc_319_;
					loc_319_ = loc_291_;
					loc_291_ = loc_320_;
					loc_320_ = loc_290_;
					loc_290_ = loc_321_;
					loc_321_ = loc_289_;
					loc_296_, loc_314_ = loc_314_, loc_296_;
					loc_297_, loc_313_ = loc_313_, loc_297_;
					loc_298_, loc_312_ = loc_312_, loc_298_;
					loc_299_, loc_311_ = loc_311_, loc_299_;
					loc_300_, loc_310_ = loc_310_, loc_300_;
					loc_301_, loc_309_ = loc_309_, loc_301_;
					loc_302_, loc_308_ = loc_308_, loc_302_;
					loc_303_, loc_307_ = loc_307_, loc_303_;
					loc_304_, loc_306_ = loc_306_, loc_304_;
				else
					loc_315_ = loc_295_;
					loc_295_ = loc_316_;
					loc_316_ = loc_294_;
					loc_294_ = loc_317_;
					loc_317_ = loc_293_;
					loc_293_ = loc_318_;
					loc_318_ = loc_292_;
					loc_292_ = loc_319_;
					loc_319_ = loc_291_;
					loc_291_ = loc_320_;
					loc_320_ = loc_290_;
					loc_290_ = loc_321_;
					loc_321_ = loc_289_;
					loc_296_, loc_314_ = loc_314_, loc_296_;
					loc_297_, loc_313_ = loc_313_, loc_297_;
					loc_298_, loc_312_ = loc_312_, loc_298_;
					loc_299_, loc_311_ = loc_311_, loc_299_;
					loc_300_, loc_310_ = loc_310_, loc_300_;
					loc_301_, loc_309_ = loc_309_, loc_301_;
					loc_302_, loc_308_ = loc_308_, loc_302_;
					loc_303_, loc_307_ = loc_307_, loc_303_;
					loc_304_, loc_306_ = loc_306_, loc_304_;
					if rt_equal_i32(loc_295_, 0) then
						loc_295_ = loc_294_;
						loc_294_ = loc_293_;
						loc_293_ = loc_292_;
						loc_292_ = loc_291_;
						loc_291_ = loc_290_;
					else
						loc_295_ = loc_294_;
						loc_294_ = loc_293_;
						loc_293_ = loc_292_;
						loc_292_ = loc_291_;
						loc_291_ = loc_290_;
						if rt_equal_i32(loc_295_, 0) then
							loc_295_ = loc_294_;
							loc_294_ = loc_293_;
							loc_293_ = loc_292_;
							loc_292_ = loc_291_;
						else
							loc_295_ = loc_294_;
							loc_294_ = loc_293_;
							loc_293_ = loc_292_;
							loc_292_ = loc_291_;
							if rt_equal_i32(loc_295_, 0) then
								loc_295_ = loc_294_;
								loc_294_ = loc_293_;
								loc_293_ = loc_292_;
							else
								loc_295_ = loc_294_;
								loc_294_ = loc_293_;
								loc_293_ = loc_292_;
								if rt_equal_i32(loc_312_, 0) then
									loc_312_ = loc_311_;
									loc_311_ = loc_310_;
									loc_310_ = loc_309_;
									loc_309_ = loc_308_;
									loc_308_ = loc_307_;
									loc_307_ = loc_306_;
									loc_306_ = loc_305_;
									loc_305_ = loc_304_;
									loc_304_ = loc_303_;
									loc_303_ = loc_302_;
									loc_302_ = loc_301_;
									loc_301_ = loc_300_;
									loc_300_ = loc_299_;
									loc_299_ = loc_298_;
									loc_298_ = loc_297_;
									loc_297_ = loc_296_;
									loc_296_ = loc_295_;
									loc_295_ = loc_294_;
									loc_294_ = loc_293_;
								else
									loc_312_ = loc_311_;
									loc_311_ = loc_310_;
									loc_310_ = loc_309_;
									loc_309_ = loc_308_;
									loc_308_ = loc_307_;
									loc_307_ = loc_306_;
									loc_306_ = loc_305_;
									loc_305_ = loc_304_;
									loc_304_ = loc_303_;
									loc_303_ = loc_302_;
									loc_302_ = loc_301_;
									loc_301_ = loc_300_;
									loc_300_ = loc_299_;
									loc_299_ = loc_298_;
									loc_298_ = loc_297_;
									loc_297_ = loc_296_;
									loc_296_ = loc_295_;
									loc_295_ = loc_294_;
									loc_294_ = loc_293_;
									if rt_equal_i32(loc_296_, 0) then
										loc_296_ = loc_295_;
										loc_295_ = loc_294_;
									else
										loc_296_ = loc_295_;
										loc_295_ = loc_294_;
										if rt_equal_i32(loc_296_, 0) then
											loc_296_ = loc_295_;
										else
											loc_296_ = loc_295_;
											if not (rt_equal_i32(loc_296_, 0)) then
												if rt_equal_i32(loc_312_, 0) then
													loc_312_ = loc_311_;
													loc_311_ = loc_310_;
													loc_310_ = loc_309_;
													loc_309_ = loc_308_;
													loc_308_ = loc_307_;
													loc_307_ = loc_306_;
													loc_306_ = loc_305_;
													loc_305_ = loc_304_;
													loc_304_ = loc_303_;
													loc_303_ = loc_302_;
													loc_302_ = loc_301_;
													loc_301_ = loc_300_;
													loc_300_ = loc_299_;
													loc_299_ = loc_298_;
													loc_298_ = loc_297_;
												else
													loc_312_ = loc_311_;
													loc_311_ = loc_310_;
													loc_310_ = loc_309_;
													loc_309_ = loc_308_;
													loc_308_ = loc_307_;
													loc_307_ = loc_306_;
													loc_306_ = loc_305_;
													loc_305_ = loc_304_;
													loc_304_ = loc_303_;
													loc_303_ = loc_302_;
													loc_302_ = loc_301_;
													loc_301_ = loc_300_;
													loc_300_ = loc_299_;
													loc_299_ = loc_298_;
													loc_298_ = loc_297_;
													if not (rt_equal_i32(loc_298_, 0)) then
														if not (rt_equal_i32(loc_299_, 0)) then
															if rt_equal_i32(loc_301_, 0) then
																loc_301_ = loc_300_;
															else
																loc_301_ = loc_300_;
																if rt_equal_i32(loc_302_, 0) then
																	loc_302_ = loc_301_;
																else
																	loc_302_ = loc_301_;
																	if rt_equal_i32(loc_304_, 0) then
																		loc_304_ = loc_303_;
																		loc_303_ = loc_302_;
																	else
																		loc_304_ = loc_303_;
																		loc_303_ = loc_302_;
																		if rt_equal_i32(loc_305_, 0) then
																			loc_305_ = loc_304_;
																			loc_304_ = loc_303_;
																		else
																			loc_305_ = loc_304_;
																			loc_304_ = loc_303_;
																			if rt_equal_i32(loc_306_, 0) then
																				loc_306_ = loc_305_;
																				loc_305_ = loc_304_;
																			else
																				loc_306_ = loc_305_;
																				loc_305_ = loc_304_;
																				if rt_equal_i32(loc_307_, 0) then
																					loc_307_ = loc_306_;
																					loc_306_ = loc_305_;
																				else
																					loc_307_ = loc_306_;
																					loc_306_ = loc_305_;
																					if rt_equal_i32(loc_308_, 0) then
																						loc_308_ = loc_307_;
																						loc_307_ = loc_306_;
																					else
																						loc_308_ = loc_307_;
																						loc_307_ = loc_306_;
																						if rt_equal_i32(loc_309_, 0) then
																							loc_309_ = loc_308_;
																							loc_308_ = loc_307_;
																						else
																							loc_309_ = loc_308_;
																							loc_308_ = loc_307_;
																							if rt_equal_i32(loc_311_, 0) then
																								loc_311_ = loc_310_;
																								loc_310_ = loc_309_;
																								loc_309_ = loc_308_;
																							else
																								loc_311_ = loc_310_;
																								loc_310_ = loc_309_;
																								loc_309_ = loc_308_;
																								if rt_equal_i32(loc_312_, 0) then
																									loc_312_ = loc_311_;
																									loc_311_ = loc_310_;
																									loc_310_ = loc_309_;
																								else
																									loc_312_ = loc_311_;
																									loc_311_ = loc_310_;
																									loc_310_ = loc_309_;
																									if rt_equal_i32(loc_313_, 0) then
																										loc_313_ = loc_312_;
																										loc_312_ = loc_311_;
																										loc_311_ = loc_310_;
																									else
																										loc_313_ = loc_312_;
																										loc_312_ = loc_311_;
																										loc_311_ = loc_310_;
																										if rt_equal_i32(loc_314_, 0) then
																											loc_314_ = loc_313_;
																											loc_313_ = loc_312_;
																											loc_312_ = loc_311_;
																										else
																											loc_314_ = loc_313_;
																											loc_313_ = loc_312_;
																											loc_312_ = loc_311_;
																											if rt_equal_i32(loc_315_, 0) then
																												loc_315_ = loc_314_;
																												loc_314_ = loc_313_;
																												loc_313_ = loc_312_;
																											else
																												loc_315_ = loc_314_;
																												loc_314_ = loc_313_;
																												loc_313_ = loc_312_;
																												if rt_equal_i32(loc_317_, 0) then
																													loc_317_ = loc_316_;
																													loc_316_ = loc_315_;
																													loc_315_ = loc_314_;
																													loc_314_ = loc_313_;
																												else
																													loc_317_ = loc_316_;
																													loc_316_ = loc_315_;
																													loc_315_ = loc_314_;
																													loc_314_ = loc_313_;
																													if rt_equal_i32(loc_318_, 0) then
																														loc_318_ = loc_317_;
																														loc_317_ = loc_316_;
																														loc_316_ = loc_315_;
																														loc_315_ = loc_314_;
																													else
																														loc_318_ = loc_317_;
																														loc_317_ = loc_316_;
																														loc_316_ = loc_315_;
																														loc_315_ = loc_314_;
																														if rt_equal_i32(loc_319_, 0) then
																															loc_319_ = loc_318_;
																															loc_318_ = loc_317_;
																															loc_317_ = loc_316_;
																															loc_316_ = loc_315_;
																														else
																															loc_319_ = loc_318_;
																															loc_318_ = loc_317_;
																															loc_317_ = loc_316_;
																															loc_316_ = loc_315_;
																															if rt_equal_i32(loc_319_, 0) then
																																loc_319_ = loc_318_;
																																loc_318_ = loc_317_;
																																loc_317_ = loc_316_;
																															else
																																loc_319_ = loc_318_;
																																loc_318_ = loc_317_;
																																loc_317_ = loc_316_;
																																if rt_equal_i32(loc_319_, 0) then
																																	loc_319_ = loc_318_;
																																	loc_318_ = loc_317_;
																																else
																																	loc_319_ = loc_318_;
																																	loc_318_ = loc_317_;
																																	loc_317_ = loc_283_;
																																	if not (rt_less_than_s32(loc_320_, 1)) then
																																		loc_314_ = loc_319_;
																																		loc_315_ = loc_318_;
																																		loc_319_ = loc_320_;
																																		loc_320_ = 0;
																																		loc_318_ = 0;
																																		loc_317_ = rt_shift_left_i32(loc_315_, 2);
																																		loc_316_ = loc_314_;
																																		loc_314_ = rt_convert_s32_to_f32(loc_314_);
																																		repeat
																																			rt_yield_budget = rt_yield_budget - 1
																																			if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																																			if rt_less_than_s32(loc_316_, 2) then
																																				loc_312_ = loc_319_;
																																			else
																																				loc_311_ = loc_318_;
																																				loc_319_, loc_320_ = loc_320_, loc_319_;
																																				loc_320_ = loc_319_;
																																				loc_313_ = 0;
																																				loc_312_ = loc_315_;
																																				loc_318_ = loc_311_;
																																				loc_311_ = rt_convert_u32_to_f32(loc_311_);
																																				repeat
																																					rt_yield_budget = rt_yield_budget - 1
																																					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																																					loc_307_ = loc_286_;
																																					loc_308_ = loc_285_;
																																					loc_309_ = loc_287_;
																																					loc_285_ = loc_308_;
																																					loc_286_ = loc_307_;
																																					loc_287_ = loc_309_;
																																					loc_310_ = loc_282_;
																																					loc_309_ = loc_309_[1](1e4 --[[ 10000_f32 ]], rt_divide_f32(rt_convert_u32_to_f32(loc_313_), loc_314_), loc_310_)
																																					loc_309_ = rt_multiply_f32(rt_divide_f32(1e0 --[[ 1_f32 ]], loc_309_), loc_311_);
																																					loc_306_ = loc_307_[1](loc_309_, loc_310_)
																																					loc_307_ = buffer_read_i32(loc_284_[1], loc_321_, 188);
																																					rt_store_f32(loc_284_, bit32_or(loc_307_ + loc_319_, 0), 0, loc_306_)
																																					loc_309_ = loc_308_[1](loc_309_, loc_310_)
																																					loc_310_ = buffer_read_i32(loc_284_[1], loc_321_, 192);
																																					rt_store_f32(loc_284_, bit32_or(loc_310_ + loc_319_, 0), 0, loc_309_)
																																					loc_319_ = bit32_or(loc_319_ + 4, 0);
																																					loc_313_ = bit32_or(loc_313_ + 2, 0);
																																					loc_310_ = bit32_or(loc_312_ + -1, 0);
																																					loc_312_ = loc_310_;
																																				until loc_310_ == 0
																																				loc_312_ = buffer_read_i32(loc_284_[1], loc_321_, 24);
																																			end
																																			loc_320_ = bit32_or(loc_320_ + loc_317_, 0);
																																			loc_319_ = loc_312_;
																																			loc_313_ = bit32_or(loc_318_ + 1, 0);
																																			loc_318_ = loc_313_;
																																		until not (rt_less_than_s32(loc_313_, loc_312_))
																																	end
																																	loc_283_ = 0;
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
			return loc_283_, loc_282_
		end), "i32->i32")
	end)(module_locals[37], module_locals[38], module_locals[39], module_locals[161], module_locals[3]);
	do (function() --[[spider:chunk]]
	module_locals[47] = { nil };
	module_locals[47][1] = (function(loc_322_)
		return rt_function_type(--[[fn:model_set_kprof]](function(loc_323_, loc_324_)
			local loc_325_, loc_326_
			rt_store_i32(loc_322_, 0, 10932, loc_323_)
			loc_326_ = loc_322_;
			loc_325_ = loc_324_;
			return loc_325_
		end), "i32->")
	end)(module_locals[3]);
	module_locals[48] = { nil };
	module_locals[48][1] = (function(loc_327_)
		return rt_function_type(--[[fn:model_set_host_kernels]](function(loc_328_, loc_329_, loc_330_)
			local loc_331_, loc_332_
			rt_store_i32(loc_327_, 0, 10940, loc_329_)
			loc_332_ = loc_327_;
			rt_store_i32(loc_332_, 0, 10936, loc_328_)
			loc_331_ = loc_330_;
			return loc_331_
		end), "i32,i32->")
	end)(module_locals[3]);
	module_locals[49] = { nil };
	module_locals[50] = { nil };
	module_locals[51] = { nil };
	module_locals[52] = { nil };
	module_locals[53] = { nil };
	module_locals[54] = { nil };
	module_locals[55] = { nil };
	module_locals[56] = { nil };
	module_locals[57] = { nil };
	end)() end --[[/spider:chunk]]
	module_locals[49][1] = (function(loc_333_, loc_334_, loc_335_, loc_336_, loc_337_, loc_338_, loc_339_, loc_340_, loc_341_, loc_342_)
		return rt_function_type(--[[fn:model_forward]](function(loc_343_, loc_344_, loc_345_, loc_346_)
			local loc_347_, loc_348_, loc_349_, loc_350_, loc_351_, loc_352_, loc_353_, loc_354_, loc_355_, loc_356_, loc_357_, loc_358_, loc_359_, loc_360_, loc_361_, loc_362_, loc_363_, loc_364_, loc_365_, loc_366_, loc_367_, loc_368_, loc_369_, loc_370_, loc_371_, loc_372_, loc_373_, loc_374_, loc_375_, loc_376_, loc_377_, loc_378_, loc_379_, loc_380_, loc_381_, loc_382_, loc_383_, loc_384_, loc_385_
			loc_383_ = buffer_read_i32(loc_342_[1], loc_343_, 12);
			loc_350_ = loc_342_;
			loc_385_ = buffer_read_i32(loc_350_[1], loc_343_, 16);
			loc_362_ = buffer_read_i32(loc_350_[1], loc_343_, 0);
			loc_369_ = buffer_read_i32(loc_350_[1], loc_343_, 4);
			loc_361_ = buffer_read_i32(loc_350_[1], loc_343_, 76);
			loc_363_ = buffer_read_i32(loc_350_[1], loc_343_, 204);
			loc_384_ = buffer_read_i32(loc_350_[1], 0, 10932);
			loc_365_ = rt_divide_s32(loc_383_, loc_385_);
			loc_366_ = rt_divide_s32(loc_362_, loc_383_);
			loc_367_ = rt_divide_s32(loc_366_, 2);
			loc_368_ = rt_divide_s32(rt_multiply_i32(loc_385_, loc_362_), loc_383_);
			loc_360_ = 0;
			loc_383_ = loc_365_;
			loc_385_ = loc_346_;
			loc_383_ = loc_366_;
			loc_383_ = loc_367_;
			loc_383_ = loc_368_;
			if rt_not_equal_i32(loc_384_, 0) then
				loc_347_ = loc_345_;
				loc_348_ = loc_343_;
				loc_349_ = loc_341_;
				loc_351_ = loc_333_;
				loc_352_ = loc_334_;
				loc_353_ = loc_335_;
				loc_354_ = loc_336_;
				loc_355_ = loc_337_;
				loc_356_ = loc_338_;
				loc_357_ = loc_339_;
				loc_358_ = loc_340_;
				loc_359_ = loc_344_;
				loc_384_ = rt_table_get_function(loc_349_, loc_384_, "i32,i32->");
				loc_384_(0, 0, loc_385_)
				loc_385_ = buffer_read_i32(loc_350_[1], 0, 10932);
				loc_383_ = buffer_read_i32(loc_350_[1], loc_348_, 28);
				loc_351_[1](loc_361_, loc_383_, loc_359_, loc_362_, loc_363_, loc_384_)
				if not (rt_equal_i32(loc_385_, 0)) then
					loc_384_ = loc_360_;
					loc_384_ = rt_table_get_function(loc_349_, loc_385_, "i32,i32->");
					loc_385_ = loc_364_;
					loc_384_(0, 1, loc_385_)
					loc_360_ = buffer_read_i32(loc_350_[1], 0, 10932);
				end
			else
				loc_347_ = loc_345_;
				loc_348_ = loc_343_;
				loc_349_ = loc_341_;
				loc_352_ = loc_334_;
				loc_353_ = loc_335_;
				loc_354_ = loc_336_;
				loc_355_ = loc_337_;
				loc_356_ = loc_338_;
				loc_357_ = loc_339_;
				loc_358_ = loc_340_;
				loc_359_ = loc_344_;
				loc_383_ = loc_333_;
				loc_351_ = loc_383_;
				loc_384_ = buffer_read_i32(loc_350_[1], loc_348_, 28);
				loc_383_[1](loc_361_, loc_384_, loc_359_, loc_362_, loc_363_, loc_385_)
			end
			loc_385_ = buffer_read_i32(loc_350_[1], loc_348_, 8);
			if not (rt_less_than_s32(loc_385_, 1)) then
				loc_379_ = loc_359_;
				loc_380_ = loc_369_;
				loc_381_ = loc_362_;
				loc_382_ = loc_348_;
				loc_383_ = loc_367_;
				loc_384_ = loc_347_;
				loc_385_ = loc_368_;
				loc_348_ = loc_382_;
				loc_359_ = bit32_or(loc_382_ + 116, 0);
				loc_369_ = loc_384_;
				loc_368_ = 0;
				loc_367_ = loc_365_;
				loc_362_ = loc_381_;
				loc_365_ = 0;
				loc_347_ = loc_385_;
				loc_370_ = loc_380_;
				loc_371_ = rt_shift_left_i32(loc_381_, 2);
				loc_372_ = bit32_or(loc_382_ + 124, 0);
				loc_373_ = rt_shift_left_i32(loc_385_, 2);
				loc_374_ = rt_shift_left_i32(rt_multiply_i32(loc_383_, loc_384_), 2);
				loc_375_ = rt_shift_left_i32(rt_multiply_i32(loc_385_, loc_384_), 2);
				loc_376_ = 0;
				loc_377_ = 0;
				repeat
					rt_yield_budget = rt_yield_budget - 1
					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
					loc_384_ = 0;
					if rt_equal_i32(loc_360_, 0) then
						loc_378_ = loc_377_;
						loc_377_ = loc_376_;
						loc_376_ = loc_347_;
						loc_383_ = loc_360_;
						loc_385_ = loc_364_;
					else
						loc_378_ = loc_377_;
						loc_377_ = loc_376_;
						loc_376_ = loc_347_;
						loc_383_ = loc_360_;
						loc_385_ = loc_364_;
						loc_384_ = rt_table_get_function(loc_349_, loc_383_, "i32,i32->");
						loc_384_(1, 0, loc_385_)
						loc_384_ = buffer_read_i32(loc_350_[1], 0, 10932);
					end
					loc_382_ = buffer_read_i32(loc_350_[1], loc_348_, 80);
					loc_383_ = buffer_read_i32(loc_350_[1], loc_348_, 32);
					loc_352_[1](loc_382_, loc_361_, bit32_or(loc_383_ + loc_365_, 0), loc_362_, loc_385_)
					if rt_equal_i32(loc_384_, 0) then
						loc_384_ = 0;
					else
						loc_384_ = rt_table_get_function(loc_349_, loc_384_, "i32,i32->");
						loc_384_(1, 1, loc_385_)
						loc_384_ = buffer_read_i32(loc_350_[1], 0, 10932);
						if rt_not_equal_i32(loc_384_, 0) then
							loc_384_ = rt_table_get_function(loc_349_, loc_384_, "i32,i32->");
							loc_384_(2, 0, loc_385_)
							loc_384_ = buffer_read_i32(loc_350_[1], 0, 10932);
							loc_383_ = buffer_read_i32(loc_350_[1], loc_348_, 80);
							loc_353_[1](loc_359_, loc_383_, loc_362_, loc_363_, loc_385_)
							if rt_equal_i32(loc_384_, 0) then
								loc_384_ = 1;
							else
								loc_384_ = rt_table_get_function(loc_349_, loc_384_, "i32,i32->");
								loc_384_(2, 1, loc_385_)
								loc_384_ = buffer_read_i32(loc_350_[1], 0, 10932);
								if rt_equal_i32(loc_384_, 0) then
									loc_384_ = 1;
								else
									loc_384_ = rt_table_get_function(loc_349_, loc_384_, "i32,i32->");
									loc_384_(3, 0, loc_385_)
									loc_384_ = 1;
								end
							end
						else
							loc_384_ = 0;
						end
					end
					if not (rt_not_equal_i32(loc_384_, 0)) then
						loc_383_ = loc_353_;
						loc_353_ = loc_383_;
						loc_384_ = buffer_read_i32(loc_350_[1], loc_348_, 80);
						loc_383_[1](loc_359_, loc_384_, loc_362_, loc_363_, loc_385_)
					end
					loc_383_ = buffer_read_i32(loc_350_[1], loc_348_, 96);
					loc_384_ = buffer_read_i32(loc_350_[1], loc_348_, 44);
					loc_354_[1](loc_383_, loc_359_, bit32_or(loc_384_ + loc_368_, 0), loc_362_, loc_362_, loc_363_, loc_385_)
					loc_383_ = buffer_read_i32(loc_350_[1], loc_348_, 100);
					loc_384_ = buffer_read_i32(loc_350_[1], loc_348_, 48);
					loc_354_[1](loc_383_, loc_359_, bit32_or(loc_384_ + loc_368_, 0), loc_362_, loc_376_, loc_363_, loc_385_)
					loc_383_ = buffer_read_i32(loc_350_[1], loc_348_, 104);
					loc_384_ = buffer_read_i32(loc_350_[1], loc_348_, 52);
					loc_354_[1](loc_383_, loc_359_, bit32_or(loc_384_ + loc_368_, 0), loc_362_, loc_376_, loc_363_, loc_385_)
					loc_383_ = buffer_read_i32(loc_350_[1], 0, 10932);
					loc_360_ = 0;
					loc_385_ = 0;
					if not (rt_equal_i32(loc_383_, 0)) then
						loc_384_, loc_385_ = loc_385_, loc_384_;
						loc_384_ = rt_table_get_function(loc_349_, loc_383_, "i32,i32->");
						loc_384_(3, 1, loc_385_)
						loc_383_ = buffer_read_i32(loc_350_[1], 0, 10932);
						loc_385_ = 0;
						if not (rt_equal_i32(loc_383_, 0)) then
							loc_384_, loc_385_ = loc_385_, loc_384_;
							loc_384_ = rt_table_get_function(loc_349_, loc_383_, "i32,i32->");
							loc_384_(4, 0, loc_385_)
							loc_385_ = buffer_read_i32(loc_350_[1], 0, 10932);
						end
					end
					loc_380_ = buffer_read_i32(loc_350_[1], loc_348_, 96);
					loc_381_ = buffer_read_i32(loc_350_[1], loc_348_, 100);
					loc_382_ = buffer_read_i32(loc_350_[1], loc_348_, 188);
					loc_383_ = buffer_read_i32(loc_350_[1], loc_348_, 192);
					loc_355_[1](loc_380_, loc_381_, bit32_or(loc_382_ + loc_374_, 0), bit32_or(loc_383_ + loc_374_, 0), loc_362_, loc_376_, loc_366_, loc_384_)
					if not (rt_equal_i32(loc_385_, 0)) then
						loc_384_ = loc_360_;
						loc_384_ = rt_table_get_function(loc_349_, loc_385_, "i32,i32->");
						loc_385_ = loc_380_;
						loc_384_(4, 1, loc_385_)
						loc_360_ = buffer_read_i32(loc_350_[1], 0, 10932);
					end
					loc_385_ = buffer_read_i32(loc_350_[1], loc_348_, 24);
					loc_385_ = rt_shift_left_i32(rt_multiply_i32(loc_377_, loc_385_), 2);
					loc_384_ = (rt_equal_i32(loc_373_, 0) and 1 or 0);
					if not (rt_not_equal_i32(loc_384_, 0)) then
						loc_382_ = buffer_read_i32(loc_350_[1], loc_348_, 180);
						loc_383_ = buffer_read_i32(loc_350_[1], loc_348_, 100);
						rt_memory_copy(loc_350_, bit32_or(bit32_or(loc_382_ + loc_385_, 0) + loc_375_, 0), loc_350_, loc_383_, loc_373_)
					end
					if not (rt_not_equal_i32(loc_384_, 0)) then
						loc_383_ = buffer_read_i32(loc_350_[1], loc_348_, 184);
						loc_384_ = buffer_read_i32(loc_350_[1], loc_348_, 104);
						rt_memory_copy(loc_350_, bit32_or(bit32_or(loc_383_ + loc_385_, 0) + loc_375_, 0), loc_350_, loc_384_, loc_373_)
					end
					if not (rt_equal_i32(loc_360_, 0)) then
						loc_383_ = rt_table_get_function(loc_349_, loc_360_, "i32,i32->");
						loc_384_ = loc_380_;
						loc_383_(5, 0, loc_384_)
					end
					loc_384_ = buffer_read_i32(loc_350_[1], loc_348_, 80);
					loc_383_ = buffer_read_i32(loc_350_[1], loc_348_, 96);
					loc_382_ = buffer_read_i32(loc_350_[1], loc_348_, 180);
					loc_381_ = buffer_read_i32(loc_350_[1], loc_348_, 184);
					loc_347_ = buffer_read_i32(loc_350_[1], loc_348_, 108);
					loc_364_ = buffer_read_i32(loc_350_[1], loc_348_, 12);
					loc_379_ = buffer_read_i32(loc_350_[1], loc_348_, 24);
					loc_356_[1](loc_384_, loc_383_, bit32_or(loc_382_ + loc_385_, 0), bit32_or(loc_381_ + loc_385_, 0), loc_347_, loc_378_, loc_369_, loc_364_, loc_366_, loc_376_, loc_367_, loc_379_, loc_380_)
					loc_379_ = buffer_read_i32(loc_350_[1], 0, 10932);
					if rt_equal_i32(loc_379_, 0) then
						loc_379_ = 0;
					else
						loc_379_ = rt_table_get_function(loc_349_, loc_379_, "i32,i32->");
						loc_379_(5, 1, loc_380_)
						loc_379_ = buffer_read_i32(loc_350_[1], 0, 10932);
						if rt_not_equal_i32(loc_379_, 0) then
							loc_379_ = rt_table_get_function(loc_349_, loc_379_, "i32,i32->");
							loc_379_(2, 0, loc_380_)
							loc_379_ = buffer_read_i32(loc_350_[1], 0, 10932);
							loc_364_ = buffer_read_i32(loc_350_[1], loc_348_, 80);
							loc_353_[1](loc_359_, loc_364_, loc_362_, loc_363_, loc_380_)
							if rt_equal_i32(loc_379_, 0) then
								loc_379_ = 1;
							else
								loc_379_ = rt_table_get_function(loc_349_, loc_379_, "i32,i32->");
								loc_379_(2, 1, loc_380_)
								loc_379_ = buffer_read_i32(loc_350_[1], 0, 10932);
								if rt_equal_i32(loc_379_, 0) then
									loc_379_ = 1;
								else
									loc_379_ = rt_table_get_function(loc_349_, loc_379_, "i32,i32->");
									loc_379_(3, 0, loc_380_)
									loc_379_ = 1;
								end
							end
						else
							loc_379_ = 0;
						end
					end
					if not (rt_not_equal_i32(loc_379_, 0)) then
						loc_364_ = loc_353_;
						loc_353_ = loc_364_;
						loc_379_ = buffer_read_i32(loc_350_[1], loc_348_, 80);
						loc_364_[1](loc_359_, loc_379_, loc_362_, loc_363_, loc_380_)
					end
					loc_364_ = buffer_read_i32(loc_350_[1], loc_348_, 84);
					loc_379_ = buffer_read_i32(loc_350_[1], loc_348_, 56);
					loc_354_[1](loc_364_, loc_359_, bit32_or(loc_379_ + loc_368_, 0), loc_362_, loc_362_, loc_363_, loc_380_)
					loc_364_ = buffer_read_i32(loc_350_[1], 0, 10932);
					if rt_equal_i32(loc_364_, 0) then
						loc_380_ = 0;
					else
						loc_380_ = loc_379_;
						loc_379_ = loc_360_;
						loc_379_ = rt_table_get_function(loc_349_, loc_364_, "i32,i32->");
						loc_379_(3, 1, loc_380_)
						loc_379_ = buffer_read_i32(loc_350_[1], 0, 10932);
						if rt_not_equal_i32(loc_379_, 0) then
							loc_379_ = rt_table_get_function(loc_349_, loc_379_, "i32,i32->");
							loc_379_(7, 0, loc_380_)
							loc_360_ = buffer_read_i32(loc_350_[1], 0, 10932);
							loc_379_ = buffer_read_i32(loc_350_[1], loc_348_, 84);
							loc_357_[1](loc_361_, loc_379_, loc_362_, loc_380_)
							loc_364_ = 0;
							if rt_equal_i32(loc_360_, 0) then
								loc_380_ = 1;
							else
								loc_380_ = loc_379_;
								loc_379_ = loc_364_;
								loc_379_ = rt_table_get_function(loc_349_, loc_360_, "i32,i32->");
								loc_379_(7, 1, loc_380_)
								loc_360_ = buffer_read_i32(loc_350_[1], 0, 10932);
								loc_364_ = 0;
								if rt_equal_i32(loc_360_, 0) then
									loc_380_ = 1;
								else
									loc_380_ = loc_379_;
									loc_379_ = loc_364_;
									loc_379_ = rt_table_get_function(loc_349_, loc_360_, "i32,i32->");
									loc_379_(1, 0, loc_380_)
									loc_364_ = buffer_read_i32(loc_350_[1], 0, 10932);
									loc_380_ = 1;
								end
							end
						else
							loc_360_ = loc_379_;
							loc_379_ = loc_380_;
							loc_380_ = 0;
						end
					end
					if not (rt_not_equal_i32(loc_380_, 0)) then
						loc_380_ = loc_379_;
						loc_379_ = loc_364_;
						loc_364_ = loc_357_;
						loc_357_ = loc_364_;
						loc_379_ = buffer_read_i32(loc_350_[1], loc_348_, 84);
						loc_364_[1](loc_361_, loc_379_, loc_362_, loc_380_)
						loc_364_ = 0;
					end
					loc_380_ = buffer_read_i32(loc_350_[1], loc_348_, 80);
					loc_347_ = buffer_read_i32(loc_350_[1], loc_348_, 36);
					loc_352_[1](loc_380_, loc_361_, bit32_or(loc_347_ + loc_365_, 0), loc_362_, loc_379_)
					if rt_equal_i32(loc_364_, 0) then
						loc_364_ = 0;
					else
						loc_364_ = rt_table_get_function(loc_349_, loc_364_, "i32,i32->");
						loc_364_(1, 1, loc_379_)
						loc_364_ = buffer_read_i32(loc_350_[1], 0, 10932);
						if rt_not_equal_i32(loc_364_, 0) then
							loc_364_ = rt_table_get_function(loc_349_, loc_364_, "i32,i32->");
							loc_364_(2, 0, loc_379_)
							loc_364_ = buffer_read_i32(loc_350_[1], 0, 10932);
							loc_347_ = buffer_read_i32(loc_350_[1], loc_348_, 80);
							loc_353_[1](loc_359_, loc_347_, loc_362_, loc_363_, loc_379_)
							if rt_equal_i32(loc_364_, 0) then
								loc_364_ = 1;
							else
								loc_364_ = rt_table_get_function(loc_349_, loc_364_, "i32,i32->");
								loc_364_(2, 1, loc_379_)
								loc_364_ = buffer_read_i32(loc_350_[1], 0, 10932);
								if rt_equal_i32(loc_364_, 0) then
									loc_364_ = 1;
								else
									loc_364_ = rt_table_get_function(loc_349_, loc_364_, "i32,i32->");
									loc_364_(3, 0, loc_379_)
									loc_364_ = 1;
								end
							end
						else
							loc_364_ = 0;
						end
					end
					if not (rt_not_equal_i32(loc_364_, 0)) then
						loc_347_ = loc_353_;
						loc_353_ = loc_347_;
						loc_364_ = buffer_read_i32(loc_350_[1], loc_348_, 80);
						loc_347_[1](loc_359_, loc_364_, loc_362_, loc_363_, loc_379_)
					end
					loc_347_ = buffer_read_i32(loc_350_[1], loc_348_, 88);
					loc_364_ = buffer_read_i32(loc_350_[1], loc_348_, 60);
					loc_354_[1](loc_347_, loc_359_, bit32_or(loc_364_ + loc_368_, 0), loc_362_, loc_370_, loc_363_, loc_379_)
					loc_347_ = buffer_read_i32(loc_350_[1], loc_348_, 92);
					loc_364_ = buffer_read_i32(loc_350_[1], loc_348_, 68);
					loc_354_[1](loc_347_, loc_359_, bit32_or(loc_364_ + loc_368_, 0), loc_362_, loc_370_, loc_363_, loc_379_)
					loc_364_ = buffer_read_i32(loc_350_[1], 0, 10932);
					if not (rt_equal_i32(loc_364_, 0)) then
						loc_364_ = rt_table_get_function(loc_349_, loc_364_, "i32,i32->");
						loc_364_(3, 1, loc_379_)
						loc_364_ = buffer_read_i32(loc_350_[1], 0, 10932);
						if not (rt_equal_i32(loc_364_, 0)) then
							loc_364_ = rt_table_get_function(loc_349_, loc_364_, "i32,i32->");
							loc_364_(6, 0, loc_379_)
						end
					end
					loc_347_ = buffer_read_i32(loc_350_[1], loc_348_, 88);
					loc_364_ = buffer_read_i32(loc_350_[1], loc_348_, 92);
					loc_358_[1](loc_347_, loc_364_, loc_370_, loc_379_)
					loc_364_ = buffer_read_i32(loc_350_[1], 0, 10932);
					if rt_equal_i32(loc_364_, 0) then
						loc_364_ = 0;
					else
						loc_364_ = rt_table_get_function(loc_349_, loc_364_, "i32,i32->");
						loc_364_(6, 1, loc_379_)
						loc_364_ = buffer_read_i32(loc_350_[1], 0, 10932);
						if rt_not_equal_i32(loc_364_, 0) then
							loc_364_ = rt_table_get_function(loc_349_, loc_364_, "i32,i32->");
							loc_364_(2, 0, loc_379_)
							loc_364_ = buffer_read_i32(loc_350_[1], 0, 10932);
							loc_347_ = buffer_read_i32(loc_350_[1], loc_348_, 88);
							loc_353_[1](loc_372_, loc_347_, loc_370_, loc_363_, loc_379_)
							if rt_equal_i32(loc_364_, 0) then
								loc_364_ = 1;
							else
								loc_364_ = rt_table_get_function(loc_349_, loc_364_, "i32,i32->");
								loc_364_(2, 1, loc_379_)
								loc_364_ = buffer_read_i32(loc_350_[1], 0, 10932);
								if rt_equal_i32(loc_364_, 0) then
									loc_364_ = 1;
								else
									loc_364_ = rt_table_get_function(loc_349_, loc_364_, "i32,i32->");
									loc_364_(3, 0, loc_379_)
									loc_364_ = 1;
								end
							end
						else
							loc_364_ = 0;
						end
					end
					if not (rt_not_equal_i32(loc_364_, 0)) then
						loc_347_ = loc_353_;
						loc_353_ = loc_347_;
						loc_364_ = buffer_read_i32(loc_350_[1], loc_348_, 88);
						loc_347_[1](loc_372_, loc_364_, loc_370_, loc_363_, loc_379_)
					end
					loc_347_ = buffer_read_i32(loc_350_[1], loc_348_, 80);
					loc_364_ = buffer_read_i32(loc_350_[1], loc_348_, 64);
					loc_354_[1](loc_347_, loc_372_, bit32_or(loc_364_ + loc_368_, 0), loc_370_, loc_362_, loc_363_, loc_379_)
					loc_379_ = buffer_read_i32(loc_350_[1], 0, 10932);
					if rt_equal_i32(loc_379_, 0) then
						loc_379_ = 0;
					else
						loc_364_, loc_379_ = loc_379_, loc_364_;
						loc_364_ = rt_table_get_function(loc_349_, loc_364_, "i32,i32->");
						loc_364_(3, 1, loc_379_)
						loc_364_ = buffer_read_i32(loc_350_[1], 0, 10932);
						if rt_not_equal_i32(loc_364_, 0) then
							loc_364_ = rt_table_get_function(loc_349_, loc_364_, "i32,i32->");
							loc_364_(7, 0, loc_379_)
							loc_379_ = buffer_read_i32(loc_350_[1], 0, 10932);
							loc_360_ = buffer_read_i32(loc_350_[1], loc_348_, 80);
							loc_357_[1](loc_361_, loc_360_, loc_362_, loc_364_)
							loc_360_ = 0;
							if rt_equal_i32(loc_379_, 0) then
								loc_379_ = 1;
							else
								loc_364_, loc_379_ = loc_379_, loc_364_;
								loc_364_ = rt_table_get_function(loc_349_, loc_364_, "i32,i32->");
								loc_364_(7, 1, loc_379_)
								loc_360_ = buffer_read_i32(loc_350_[1], 0, 10932);
								loc_379_ = 1;
							end
						else
							loc_364_, loc_379_ = loc_379_, loc_364_;
							loc_379_ = 0;
						end
					end
					if not (rt_not_equal_i32(loc_379_, 0)) then
						loc_379_ = loc_364_;
						loc_364_ = loc_360_;
						loc_360_ = loc_357_;
						loc_357_ = loc_360_;
						loc_364_ = buffer_read_i32(loc_350_[1], loc_348_, 80);
						loc_360_[1](loc_361_, loc_364_, loc_362_, loc_379_)
						loc_360_ = 0;
					end
					loc_379_ = buffer_read_i32(loc_350_[1], loc_348_, 8);
					loc_368_ = bit32_or(loc_368_ + 8, 0);
					loc_365_ = bit32_or(loc_365_ + loc_371_, 0);
					loc_347_ = loc_376_;
					loc_376_ = bit32_or(loc_377_ + loc_376_, 0);
					loc_378_ = bit32_or(loc_378_ + 1, 0);
					loc_377_ = loc_378_;
				until not (rt_less_than_s32(loc_378_, loc_379_))
			end
			if rt_not_equal_i32(loc_360_, 0) then
				loc_360_ = rt_table_get_function(loc_349_, loc_360_, "i32,i32->");
				loc_360_(1, 0, loc_364_)
				loc_360_ = buffer_read_i32(loc_350_[1], 0, 10932);
				loc_359_ = buffer_read_i32(loc_350_[1], loc_348_, 40);
				loc_352_[1](loc_361_, loc_361_, loc_359_, loc_362_, loc_364_)
				if rt_not_equal_i32(loc_360_, 0) then
					loc_360_ = rt_table_get_function(loc_349_, loc_360_, "i32,i32->");
					loc_360_(1, 1, loc_364_)
					loc_359_ = buffer_read_i32(loc_350_[1], 0, 10932);
					if rt_not_equal_i32(loc_359_, 0) then
						loc_364_ = bit32_or(loc_348_ + 116, 0);
						loc_359_ = rt_table_get_function(loc_349_, loc_359_, "i32,i32->");
						loc_359_(2, 0, loc_360_)
						loc_360_ = buffer_read_i32(loc_350_[1], 0, 10932);
						loc_353_[1](loc_364_, loc_361_, loc_362_, loc_363_, loc_359_)
						if rt_equal_i32(loc_360_, 0) then
							loc_360_ = 1;
						else
							loc_359_, loc_360_ = loc_360_, loc_359_;
							loc_359_ = rt_table_get_function(loc_349_, loc_359_, "i32,i32->");
							loc_359_(2, 1, loc_360_)
							loc_360_ = buffer_read_i32(loc_350_[1], 0, 10932);
							if rt_equal_i32(loc_360_, 0) then
								loc_360_ = 1;
							else
								loc_359_, loc_360_ = loc_360_, loc_359_;
								loc_359_ = rt_table_get_function(loc_349_, loc_359_, "i32,i32->");
								loc_359_(8, 0, loc_360_)
								loc_360_ = 1;
							end
						end
					else
						loc_364_ = loc_359_;
						loc_359_ = loc_360_;
						loc_360_ = 0;
					end
				else
					loc_359_ = loc_353_;
					loc_360_, loc_364_ = loc_364_, loc_360_;
					loc_353_ = loc_359_;
					loc_364_ = bit32_or(loc_348_ + 116, 0);
					loc_359_[1](loc_364_, loc_361_, loc_362_, loc_363_, loc_360_)
					loc_360_ = 1;
				end
			else
				loc_347_ = loc_352_;
				loc_359_, loc_360_ = loc_360_, loc_359_;
				loc_360_, loc_364_ = loc_364_, loc_360_;
				loc_352_ = loc_347_;
				loc_359_ = buffer_read_i32(loc_350_[1], loc_348_, 40);
				loc_347_[1](loc_361_, loc_361_, loc_359_, loc_362_, loc_360_)
				loc_360_ = 0;
			end
			if not (rt_not_equal_i32(loc_360_, 0)) then
				loc_360_ = loc_359_;
				loc_359_ = loc_353_;
				loc_353_ = loc_359_;
				loc_364_ = bit32_or(loc_348_ + 116, 0);
				loc_359_[1](loc_364_, loc_361_, loc_362_, loc_363_, loc_360_)
			end
			loc_361_ = buffer_read_i32(loc_350_[1], loc_348_, 112);
			loc_360_ = buffer_read_i32(loc_350_[1], loc_348_, 72);
			loc_347_ = buffer_read_i32(loc_350_[1], loc_348_, 20);
			loc_354_[1](loc_361_, loc_364_, loc_360_, loc_362_, loc_347_, loc_363_, loc_359_)
			loc_359_ = buffer_read_i32(loc_350_[1], 0, 10932);
			if not (rt_equal_i32(loc_359_, 0)) then
				loc_347_, loc_359_ = loc_359_, loc_347_;
				loc_347_ = rt_table_get_function(loc_349_, loc_347_, "i32,i32->");
				loc_347_(8, 1, loc_359_)
			end
			loc_348_ = buffer_read_i32(loc_350_[1], loc_348_, 112);
			return loc_348_, loc_347_
		end), "i32,i32,i32->i32")
	end)(module_locals[50], module_locals[51], module_locals[52], module_locals[53], module_locals[54], module_locals[55], module_locals[56], module_locals[57], module_locals[162], module_locals[3]);
	do (function() --[[spider:chunk]]
	module_locals[50][1] = (function(loc_386_)
		return rt_function_type(--[[fn:k_embed]](function(loc_387_, loc_388_, loc_389_, loc_390_, loc_391_, loc_392_)
			local loc_393_, loc_394_, loc_395_, loc_396_, loc_397_, loc_398_, loc_399_, loc_400_, loc_401_, loc_402_, loc_403_, loc_404_, loc_405_, loc_406_
			loc_397_ = rt_multiply_i32(loc_390_, loc_389_);
			loc_400_ = rt_divide_s32(loc_397_, loc_391_);
			loc_393_ = loc_392_;
			loc_406_ = loc_400_;
			if rt_less_than_s32(loc_390_, 1) then
				loc_394_ = loc_386_;
				loc_395_ = loc_387_;
				loc_396_ = loc_388_;
				loc_398_ = loc_390_;
				loc_399_ = loc_391_;
			else
				loc_394_ = loc_386_;
				loc_395_ = loc_387_;
				loc_396_ = loc_388_;
				loc_404_ = loc_390_;
				loc_405_ = loc_391_;
				loc_406_ = buffer_read_i32(loc_394_[1], loc_396_, 0);
				loc_403_ = buffer_read_i32(loc_394_[1], loc_396_, 4);
				loc_399_ = 0;
				loc_398_ = bit32_or(loc_403_ + rt_shift_left_i32(loc_400_, 2), 0);
				loc_396_ = bit32_or(loc_406_ + loc_397_, 0);
				loc_406_ = rt_and_i32(loc_404_, 1);
				if rt_equal_i32(loc_404_, 1) then
					loc_397_ = loc_405_;
					loc_400_ = loc_395_;
					loc_395_ = loc_406_;
					loc_401_ = loc_404_;
				else
					loc_397_ = loc_405_;
					loc_405_ = loc_395_;
					loc_395_ = loc_406_;
					loc_406_ = loc_404_;
					loc_404_ = loc_399_;
					loc_400_ = loc_405_;
					loc_399_ = 0;
					loc_401_ = loc_405_;
					loc_402_ = rt_and_i32(loc_406_, 2147483646);
					repeat
						rt_yield_budget = rt_yield_budget - 1
						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
						loc_404_ = loc_402_;
						loc_406_ = rt_divide_s32(loc_399_, loc_397_);
						loc_402_ = rt_load_f32(loc_394_, bit32_or(loc_398_ + rt_shift_left_i32(loc_406_, 2), 0), 0);
						loc_403_ = bit32_or(loc_396_ + loc_399_, 0);
						loc_405_ = rt_load_i32_from_s8(loc_394_, loc_403_, 0);
						rt_store_f32(loc_394_, loc_401_, 0, rt_multiply_f32(loc_402_, rt_convert_s32_to_f32(loc_405_)))
						loc_405_ = rt_divide_s32(bit32_or(loc_399_ + 1, 0), loc_397_);
						loc_402_ = rt_load_f32(loc_394_, bit32_or(loc_398_ + rt_shift_left_i32(loc_405_, 2), 0), 0);
						loc_403_ = rt_load_i32_from_s8(loc_394_, bit32_or(loc_403_ + 1, 0), 0);
						rt_store_f32(loc_394_, bit32_or(loc_401_ + 4, 0), 0, rt_multiply_f32(loc_402_, rt_convert_s32_to_f32(loc_403_)))
						loc_403_ = bit32_or(loc_399_ + 2, 0);
						loc_399_ = loc_403_;
						loc_401_ = bit32_or(loc_401_ + 8, 0);
						loc_402_ = loc_404_;
					until not (rt_not_equal_i32(loc_403_, loc_404_))
				end
				if not (rt_equal_i32(loc_395_, 0)) then
					loc_396_, loc_400_ = loc_400_, loc_396_;
					loc_400_, loc_397_ = loc_397_, loc_400_;
					loc_397_, loc_398_ = loc_398_, loc_397_;
					loc_400_ = rt_divide_s32(loc_399_, loc_400_);
					loc_397_ = rt_load_f32(loc_394_, bit32_or(loc_397_ + rt_shift_left_i32(loc_400_, 2), 0), 0);
					loc_398_ = rt_load_i32_from_s8(loc_394_, bit32_or(loc_398_ + loc_399_, 0), 0);
					rt_store_f32(loc_394_, bit32_or(loc_396_ + rt_shift_left_i32(loc_399_, 2), 0), 0, rt_multiply_f32(loc_397_, rt_convert_s32_to_f32(loc_398_)))
				end
			end
			return loc_393_
		end), "i32,i32,i32,i32,i32->")
	end)(module_locals[3]);
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[51][1] = (function(loc_407_)
		return rt_function_type(--[[fn:k_rmsnorm]](function(loc_408_, loc_409_, loc_410_, loc_411_, loc_412_)
			local loc_413_, loc_414_, loc_415_, loc_416_, loc_417_, loc_418_, loc_419_, loc_420_, loc_421_, loc_422_, loc_423_, loc_424_, loc_425_, loc_426_, loc_427_
			if rt_less_than_s32(loc_411_, 1) then
				loc_413_ = loc_412_;
				loc_414_ = loc_407_;
				loc_415_ = loc_408_;
				loc_416_ = loc_409_;
				loc_417_ = loc_410_;
				loc_418_ = loc_411_;
			else
				loc_413_ = loc_412_;
				loc_414_ = loc_407_;
				loc_415_ = loc_408_;
				loc_416_ = loc_409_;
				loc_417_ = loc_410_;
				loc_418_ = loc_411_;
				loc_425_ = rt_and_i32(loc_418_, 3);
				if rt_greater_than_equal_u32(loc_418_, 4) then
					loc_422_ = loc_416_;
					loc_416_ = loc_417_;
					loc_427_ = loc_418_;
					loc_418_ = loc_415_;
					loc_417_ = loc_422_;
					loc_421_ = loc_427_;
					loc_426_ = 0 --[[ 0_f32 ]];
					loc_424_ = 0;
					loc_423_ = rt_and_i32(loc_427_, 2147483644);
					repeat
						rt_yield_budget = rt_yield_budget - 1
						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
						loc_419_ = loc_423_;
						loc_427_ = rt_load_f32(loc_414_, loc_422_, 0);
						loc_415_ = rt_load_f32(loc_414_, bit32_or(loc_422_ + 4, 0), 0);
						loc_420_ = rt_load_f32(loc_414_, bit32_or(loc_422_ + 8, 0), 0);
						loc_423_ = rt_load_f32(loc_414_, bit32_or(loc_422_ + 12, 0), 0);
						loc_426_ = rt_add_f32(rt_add_f32(rt_add_f32(rt_add_f32(loc_426_, rt_multiply_f32(loc_427_, loc_427_)), rt_multiply_f32(loc_415_, loc_415_)), rt_multiply_f32(loc_420_, loc_420_)), rt_multiply_f32(loc_423_, loc_423_));
						loc_420_ = bit32_or(loc_424_ + 4, 0);
						loc_424_ = loc_420_;
						loc_423_ = loc_419_;
						loc_422_ = bit32_or(loc_422_ + 16, 0);
					until not (rt_not_equal_i32(loc_419_, loc_420_))
				else
					loc_422_ = loc_416_;
					loc_416_ = loc_417_;
					loc_427_ = loc_418_;
					loc_418_ = loc_415_;
					loc_417_ = loc_422_;
					loc_421_ = loc_427_;
					loc_426_ = 0 --[[ 0_f32 ]];
					loc_424_ = 0;
				end
				if not (rt_equal_i32(loc_425_, 0)) then
					loc_423_ = loc_417_;
					loc_417_ = loc_423_;
					loc_424_ = bit32_or(loc_423_ + rt_shift_left_i32(loc_424_, 2), 0);
					repeat
						rt_yield_budget = rt_yield_budget - 1
						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
						loc_422_ = rt_load_f32(loc_414_, loc_424_, 0);
						loc_423_ = bit32_or(loc_425_ + -1, 0);
						loc_425_ = loc_423_;
						loc_426_ = rt_add_f32(loc_426_, rt_multiply_f32(loc_422_, loc_422_));
						loc_424_ = bit32_or(loc_424_ + 4, 0);
					until loc_423_ == 0
				end
				loc_415_ = rt_divide_f32(1e0 --[[ 1_f32 ]], rt_square_root_f32(rt_add_f32(rt_divide_f32(loc_426_, rt_convert_u32_to_f32(loc_421_)), 9.999999747378752e-6 --[[ 0.00001_f32 ]])));
				loc_419_ = 0;
				loc_420_ = rt_and_i32(loc_421_, 1);
				if not (rt_equal_i32(loc_421_, 1)) then
					loc_423_ = loc_419_;
					loc_424_ = loc_417_;
					loc_425_ = loc_416_;
					loc_426_ = loc_418_;
					loc_418_ = loc_426_;
					loc_417_ = loc_424_;
					loc_416_ = loc_425_;
					loc_421_ = rt_and_i32(loc_421_, 2147483646);
					loc_422_ = loc_424_;
					loc_423_ = loc_425_;
					loc_419_ = 0;
					loc_424_ = loc_426_;
					repeat
						rt_yield_budget = rt_yield_budget - 1
						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
						loc_426_ = loc_421_;
						loc_421_ = rt_load_f32(loc_414_, loc_423_, 0);
						loc_425_ = rt_load_f32(loc_414_, loc_422_, 0);
						rt_store_f32(loc_414_, loc_424_, 0, rt_multiply_f32(loc_421_, rt_multiply_f32(loc_415_, loc_425_)))
						loc_421_ = rt_load_f32(loc_414_, bit32_or(loc_423_ + 4, 0), 0);
						loc_425_ = rt_load_f32(loc_414_, bit32_or(loc_422_ + 4, 0), 0);
						rt_store_f32(loc_414_, bit32_or(loc_424_ + 4, 0), 0, rt_multiply_f32(loc_421_, rt_multiply_f32(loc_415_, loc_425_)))
						loc_421_ = loc_426_;
						loc_422_ = bit32_or(loc_422_ + 8, 0);
						loc_423_ = bit32_or(loc_423_ + 8, 0);
						loc_425_ = bit32_or(loc_419_ + 2, 0);
						loc_419_ = loc_425_;
						loc_424_ = bit32_or(loc_424_ + 8, 0);
					until not (rt_not_equal_i32(loc_426_, loc_425_))
				end
				if not (rt_equal_i32(loc_420_, 0)) then
					loc_416_, loc_419_ = loc_419_, loc_416_;
					loc_419_, loc_417_ = loc_417_, loc_419_;
					loc_416_ = rt_shift_left_i32(loc_416_, 2);
					loc_417_ = rt_load_f32(loc_414_, bit32_or(loc_417_ + loc_416_, 0), 0);
					loc_419_ = rt_load_f32(loc_414_, bit32_or(loc_419_ + loc_416_, 0), 0);
					rt_store_f32(loc_414_, bit32_or(loc_418_ + loc_416_, 0), 0, rt_multiply_f32(loc_417_, rt_multiply_f32(loc_415_, loc_419_)))
				end
			end
			return loc_413_
		end), "i32,i32,i32,i32->")
	end)(module_locals[3]);
	end)() end --[[/spider:chunk]]
	module_locals[52][1] = (function(loc_428_)
		return rt_function_type(--[[fn:k_quantize]](function(loc_429_, loc_430_, loc_431_, loc_432_, loc_433_)
			local loc_434_, loc_435_, loc_436_, loc_437_, loc_438_, loc_439_, loc_440_, loc_441_, loc_442_, loc_443_, loc_444_, loc_445_, loc_446_, loc_447_, loc_448_, loc_449_, loc_450_, loc_451_, loc_452_, loc_453_, loc_454_, loc_455_, loc_456_
			loc_439_ = rt_divide_s32(loc_431_, loc_432_);
			loc_434_ = loc_433_;
			loc_456_ = loc_439_;
			if rt_less_than_s32(loc_439_, 1) then
				loc_435_ = loc_428_;
				loc_436_ = loc_429_;
				loc_437_ = loc_430_;
				loc_438_ = loc_432_;
			else
				loc_435_ = loc_428_;
				loc_436_ = loc_429_;
				loc_437_ = loc_430_;
				loc_455_ = loc_439_;
				loc_456_ = loc_432_;
				loc_439_ = loc_436_;
				loc_438_ = loc_437_;
				loc_437_ = loc_456_;
				loc_436_ = loc_455_;
				loc_440_ = rt_shift_left_i32(loc_456_, 2);
				loc_441_ = rt_and_i32(loc_456_, 2147483644);
				loc_442_ = rt_and_i32(loc_456_, 3);
				loc_443_ = (rt_less_than_s32(loc_456_, 1) and 1 or 0);
				loc_444_ = (rt_less_than_u32(loc_456_, 4) and 1 or 0);
				loc_445_ = 0;
				loc_446_ = 0;
				repeat
					rt_yield_budget = rt_yield_budget - 1
					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
					if rt_not_equal_i32(loc_443_, 0) then
						loc_447_ = loc_446_;
						loc_446_ = loc_445_;
						loc_445_ = loc_437_;
						loc_448_ = loc_436_;
						loc_437_ = buffer_read_i32(loc_435_[1], loc_439_, 4);
						rt_store_i32(loc_435_, bit32_or(loc_437_ + rt_shift_left_i32(loc_447_, 2), 0), 0, 0)
					else
						loc_447_ = loc_446_;
						loc_446_ = loc_445_;
						loc_445_ = loc_437_;
						loc_448_ = loc_436_;
						loc_452_ = 0;
						loc_451_ = 0 --[[ 0_f32 ]];
						if rt_not_equal_i32(loc_444_, 0) then
							loc_436_ = loc_446_;
							loc_437_ = loc_438_;
							loc_450_ = loc_445_;
						else
							loc_436_ = loc_446_;
							loc_450_ = loc_445_;
							loc_456_ = loc_438_;
							loc_437_ = loc_456_;
							loc_449_ = loc_456_;
							repeat
								rt_yield_budget = rt_yield_budget - 1
								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
								loc_456_ = loc_451_;
								loc_451_ = rt_load_f32(loc_435_, bit32_or(loc_449_ + 12, 0), 0);
								loc_453_ = rt_load_f32(loc_435_, bit32_or(loc_449_ + 8, 0), 0);
								loc_454_ = rt_load_f32(loc_435_, bit32_or(loc_449_ + 4, 0), 0);
								loc_455_ = rt_load_f32(loc_435_, loc_449_, 0);
								loc_451_ = rt_absolute_f32(loc_451_);
								loc_446_ = rt_absolute_f32(loc_453_);
								loc_438_ = rt_absolute_f32(loc_454_);
								loc_454_ = rt_absolute_f32(loc_455_);
								if rt_greater_than_f32(loc_454_, loc_456_) then
									loc_445_ = loc_441_;
									loc_441_ = loc_451_;
									loc_453_ = loc_446_;
									loc_455_ = loc_438_;
								else
									loc_445_ = loc_441_;
									loc_441_ = loc_451_;
									loc_453_ = loc_446_;
									loc_455_ = loc_438_;
									loc_454_ = loc_456_;
								end
								if not (rt_greater_than_f32(loc_455_, loc_454_)) then
									loc_438_ = loc_454_;
								end
								if not (rt_greater_than_f32(loc_453_, loc_438_)) then
									loc_446_ = loc_438_;
								end
								if not (rt_greater_than_f32(loc_441_, loc_446_)) then
									loc_451_ = loc_446_;
								end
								loc_449_ = bit32_or(loc_449_ + 16, 0);
								loc_441_ = loc_445_;
								loc_446_ = bit32_or(loc_452_ + 4, 0);
								loc_452_ = loc_446_;
							until not (rt_not_equal_i32(loc_445_, loc_446_))
						end
						if not (rt_equal_i32(loc_442_, 0)) then
							loc_446_ = loc_437_;
							loc_449_ = loc_442_;
							loc_437_ = loc_446_;
							loc_452_ = bit32_or(loc_446_ + rt_shift_left_i32(loc_452_, 2), 0);
							loc_442_ = loc_449_;
							repeat
								rt_yield_budget = rt_yield_budget - 1
								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
								loc_446_ = loc_451_;
								loc_451_ = rt_load_f32(loc_435_, loc_452_, 0);
								loc_451_ = rt_absolute_f32(loc_451_);
								if not (rt_greater_than_f32(loc_451_, loc_446_)) then
									loc_451_ = loc_446_;
								end
								loc_452_ = bit32_or(loc_452_ + 4, 0);
								loc_446_ = bit32_or(loc_449_ + -1, 0);
								loc_449_ = loc_446_;
							until loc_446_ == 0
						end
						loc_452_ = buffer_read_i32(loc_435_[1], loc_439_, 4);
						loc_449_ = rt_divide_f32(loc_451_, 1.27e2 --[[ 127_f32 ]]);
						rt_store_f32(loc_435_, bit32_or(loc_452_ + rt_shift_left_i32(loc_447_, 2), 0), 0, loc_449_)
						loc_438_ = loc_437_;
						loc_445_ = loc_450_;
						loc_446_ = loc_436_;
						repeat
							rt_yield_budget = rt_yield_budget - 1
							if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
							loc_452_ = rt_load_f32(loc_435_, loc_437_, 0);
							loc_452_ = rt_divide_f32(loc_452_, loc_449_);
							if rt_equal_i32((rt_greater_than_equal_f32(loc_452_, 0 --[[ 0_f32 ]]) and 1 or 0), 0) then
								loc_451_ = loc_450_;
								loc_450_ = loc_436_;
								loc_452_ = rt_negate_f32(rt_round_down_f32(rt_subtract_f32(5e-1 --[[ 0.5_f32 ]], loc_452_)));
							else
								loc_451_ = loc_450_;
								loc_450_ = loc_436_;
								loc_452_ = rt_round_down_f32(rt_add_f32(loc_452_, 5e-1 --[[ 0.5_f32 ]]));
							end
							loc_436_ = buffer_read_i32(loc_435_[1], loc_439_, 0);
							rt_store_i32_into_i8(loc_435_, bit32_or(loc_436_ + loc_450_, 0), 0, rt_saturate_f32_to_s32(loc_452_))
							loc_437_ = bit32_or(loc_437_ + 4, 0);
							loc_436_ = bit32_or(loc_450_ + 1, 0);
							loc_451_ = bit32_or(loc_451_ + -1, 0);
							loc_450_ = loc_451_;
						until loc_451_ == 0
					end
					loc_438_ = bit32_or(loc_438_ + loc_440_, 0);
					loc_437_ = loc_445_;
					loc_436_ = loc_448_;
					loc_445_ = bit32_or(loc_446_ + loc_445_, 0);
					loc_447_ = bit32_or(loc_447_ + 1, 0);
					loc_446_ = loc_447_;
				until not (rt_not_equal_i32(loc_447_, loc_448_))
			end
			return loc_434_
		end), "i32,i32,i32,i32->")
	end)(module_locals[3]);
	do (function() --[[spider:chunk]]
	module_locals[58] = { nil };
	module_locals[53][1] = (function(loc_457_, loc_458_, loc_459_)
		return rt_function_type(--[[fn:k_matvec_q8]](function(loc_460_, loc_461_, loc_462_, loc_463_, loc_464_, loc_465_, loc_466_)
			local loc_467_, loc_468_, loc_469_, loc_470_, loc_471_, loc_472_, loc_473_, loc_474_, loc_475_, loc_476_, loc_477_, loc_478_, loc_479_, loc_480_, loc_481_
			loc_477_ = buffer_read_i32(loc_459_[1], 0, 10936);
			loc_469_ = loc_459_;
			if rt_equal_i32(loc_477_, 0) then
				loc_467_ = loc_466_;
				loc_468_ = loc_458_;
				loc_470_ = loc_457_;
				loc_471_ = loc_460_;
				loc_472_ = loc_461_;
				loc_473_ = loc_462_;
				loc_474_ = loc_463_;
				loc_475_ = loc_464_;
				loc_476_ = loc_465_;
				loc_477_ = 0;
			else
				loc_468_ = loc_458_;
				loc_470_ = loc_457_;
				loc_471_ = loc_460_;
				loc_472_ = loc_461_;
				loc_473_ = loc_462_;
				loc_474_ = loc_463_;
				loc_475_ = loc_464_;
				loc_476_ = loc_465_;
				loc_481_ = loc_477_;
				loc_477_ = loc_466_;
				loc_481_ = rt_table_get_function(loc_468_, loc_481_, "i32,i32,i32,i32,i32,i32,i32,i32,i32->i32");
				loc_480_ = buffer_read_i32(loc_469_[1], loc_472_, 0);
				loc_479_ = buffer_read_i32(loc_469_[1], loc_472_, 4);
				loc_478_ = buffer_read_i32(loc_469_[1], loc_473_, 0);
				loc_467_ = buffer_read_i32(loc_469_[1], loc_473_, 4);
				loc_477_ = loc_481_(loc_471_, loc_480_, loc_479_, loc_478_, loc_467_, loc_474_, loc_475_, loc_476_, 1, loc_477_)
				if rt_not_equal_i32(loc_477_, 0) then
					loc_477_ = 1;
				else
					loc_477_ = 0;
				end
			end
			if not (rt_not_equal_i32(loc_477_, 0)) then
				loc_477_ = loc_470_;
				loc_470_ = loc_477_;
				loc_477_[1](loc_471_, loc_472_, loc_473_, loc_474_, loc_475_, loc_476_, loc_467_)
			end
			return loc_467_
		end), "i32,i32,i32,i32,i32,i32->")
	end)(module_locals[58], module_locals[162], module_locals[3]);
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[54][1] = (function(loc_482_)
		return rt_function_type(--[[fn:k_rope]](function(loc_483_, loc_484_, loc_485_, loc_486_, loc_487_, loc_488_, loc_489_, loc_490_)
			local loc_491_, loc_492_, loc_493_, loc_494_, loc_495_, loc_496_, loc_497_, loc_498_, loc_499_, loc_500_, loc_501_, loc_502_, loc_503_, loc_504_, loc_505_, loc_506_
			if rt_less_than_s32(loc_487_, 1) then
				loc_491_ = loc_490_;
				loc_492_ = loc_482_;
				loc_493_ = loc_483_;
				loc_494_ = loc_484_;
				loc_495_ = loc_485_;
				loc_496_ = loc_486_;
				loc_497_ = loc_487_;
				loc_498_ = loc_488_;
				loc_499_ = loc_489_;
			else
				loc_491_ = loc_490_;
				loc_492_ = loc_482_;
				loc_493_ = loc_483_;
				loc_494_ = loc_484_;
				loc_495_ = loc_485_;
				loc_496_ = loc_486_;
				loc_504_ = loc_487_;
				loc_505_ = loc_488_;
				loc_506_ = loc_489_;
				loc_499_ = loc_493_;
				loc_498_ = loc_494_;
				loc_497_ = loc_495_;
				loc_495_ = loc_504_;
				loc_494_ = loc_505_;
				loc_493_ = loc_506_;
				loc_500_ = 0;
				repeat
					rt_yield_budget = rt_yield_budget - 1
					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
					loc_503_ = rt_remainder_s32(loc_500_, loc_493_);
					loc_506_ = rt_and_i32(rt_shift_left_i32(loc_503_, 1), -4);
					loc_504_ = rt_load_f32(loc_492_, bit32_or(loc_496_ + loc_506_, 0), 0);
					loc_501_ = rt_load_f32(loc_492_, loc_499_, 0);
					loc_505_ = rt_load_f32(loc_492_, bit32_or(loc_497_ + loc_506_, 0), 0);
					loc_506_ = bit32_or(loc_499_ + 4, 0);
					loc_502_ = rt_load_f32(loc_492_, loc_506_, 0);
					rt_store_f32(loc_492_, loc_506_, 0, rt_add_f32(rt_multiply_f32(loc_504_, loc_501_), rt_multiply_f32(loc_505_, loc_502_)))
					rt_store_f32(loc_492_, loc_499_, 0, rt_subtract_f32(rt_multiply_f32(loc_505_, loc_501_), rt_multiply_f32(loc_504_, loc_502_)))
					if rt_greater_than_equal_s32(loc_500_, loc_494_) then
						loc_501_ = loc_500_;
						loc_500_ = loc_498_;
						loc_498_ = loc_504_;
						loc_502_ = loc_495_;
						loc_495_ = loc_505_;
					else
						loc_501_ = loc_500_;
						loc_500_ = loc_498_;
						loc_498_ = loc_504_;
						loc_502_ = loc_495_;
						loc_495_ = loc_505_;
						loc_504_ = rt_load_f32(loc_492_, loc_500_, 0);
						loc_505_ = bit32_or(loc_500_ + 4, 0);
						loc_503_ = rt_load_f32(loc_492_, loc_505_, 0);
						rt_store_f32(loc_492_, loc_505_, 0, rt_add_f32(rt_multiply_f32(loc_498_, loc_504_), rt_multiply_f32(loc_495_, loc_503_)))
						rt_store_f32(loc_492_, loc_500_, 0, rt_subtract_f32(rt_multiply_f32(loc_495_, loc_504_), rt_multiply_f32(loc_498_, loc_503_)))
					end
					loc_499_ = bit32_or(loc_499_ + 8, 0);
					loc_498_ = bit32_or(loc_500_ + 8, 0);
					loc_495_ = loc_502_;
					loc_501_ = bit32_or(loc_501_ + 2, 0);
					loc_500_ = loc_501_;
				until not (rt_less_than_s32(loc_501_, loc_502_))
			end
			return loc_491_
		end), "i32,i32,i32,i32,i32,i32,i32->")
	end)(module_locals[3]);
	module_locals[59] = { nil };
	end)() end --[[/spider:chunk]]
	module_locals[55][1] = (function(loc_507_, loc_508_, loc_509_)
		return rt_function_type(--[[fn:k_attention]](function(loc_510_, loc_511_, loc_512_, loc_513_, loc_514_, loc_515_, loc_516_, loc_517_, loc_518_, loc_519_, loc_520_, loc_521_, loc_522_)
			local loc_523_, loc_524_, loc_525_, loc_526_, loc_527_, loc_528_, loc_529_, loc_530_, loc_531_, loc_532_, loc_533_, loc_534_, loc_535_, loc_536_, loc_537_, loc_538_, loc_539_, loc_540_, loc_541_, loc_542_, loc_543_, loc_544_, loc_545_, loc_546_, loc_547_, loc_548_, loc_549_, loc_550_, loc_551_, loc_552_, loc_553_, loc_554_, loc_555_, loc_556_, loc_557_, loc_558_, loc_559_, loc_560_, loc_561_, loc_562_, loc_563_, loc_564_
			loc_563_ = buffer_read_i32(loc_509_[1], 0, 10940);
			loc_525_ = loc_509_;
			if rt_equal_i32(loc_563_, 0) then
				loc_523_ = loc_522_;
				loc_524_ = loc_508_;
				loc_526_ = loc_507_;
				loc_527_ = loc_510_;
				loc_528_ = loc_511_;
				loc_529_ = loc_512_;
				loc_530_ = loc_513_;
				loc_531_ = loc_514_;
				loc_532_ = loc_516_;
				loc_533_ = loc_517_;
				loc_534_ = loc_518_;
				loc_535_ = loc_519_;
				loc_536_ = loc_520_;
				loc_537_ = loc_521_;
				loc_564_ = loc_515_;
				if rt_less_than_s32(loc_533_, 1) then
					loc_564_ = 1;
				else
					loc_564_ = 0;
				end
			else
				loc_523_ = loc_522_;
				loc_524_ = loc_508_;
				loc_526_ = loc_507_;
				loc_527_ = loc_510_;
				loc_528_ = loc_511_;
				loc_529_ = loc_512_;
				loc_530_ = loc_513_;
				loc_531_ = loc_514_;
				loc_532_ = loc_516_;
				loc_533_ = loc_517_;
				loc_534_ = loc_518_;
				loc_535_ = loc_519_;
				loc_536_ = loc_520_;
				loc_537_ = loc_521_;
				loc_564_ = loc_515_;
				loc_562_ = rt_table_get_function(loc_524_, loc_563_, "i32,i32,i32,i32,i32,i32,i32,i32,i32,i32,i32,i32->i32");
				loc_563_ = loc_523_;
				loc_564_ = loc_562_(loc_527_, loc_528_, loc_529_, loc_530_, loc_531_, loc_564_, loc_532_, loc_533_, loc_534_, loc_535_, loc_536_, loc_537_, loc_563_)
				if rt_not_equal_i32(loc_564_, 0) then
					loc_564_ = 1;
				else
					if rt_greater_than_s32(loc_533_, 0) then
						loc_564_ = 0;
					else
						loc_564_ = 1;
					end
				end
			end
			if not (rt_not_equal_i32(loc_564_, 0)) then
				loc_558_ = loc_533_;
				loc_559_ = loc_536_;
				loc_560_ = loc_537_;
				loc_561_ = loc_535_;
				loc_562_ = loc_532_;
				loc_563_ = loc_534_;
				loc_564_ = loc_527_;
				loc_537_ = loc_564_;
				loc_536_ = loc_528_;
				loc_535_ = loc_529_;
				loc_534_ = loc_530_;
				loc_533_ = loc_531_;
				loc_532_ = loc_562_;
				loc_531_ = loc_558_;
				loc_530_ = loc_563_;
				loc_529_ = loc_561_;
				loc_528_ = loc_559_;
				loc_527_ = loc_560_;
				loc_538_ = rt_shift_left_i32(loc_561_, 2);
				loc_539_ = rt_shift_left_i32(loc_563_, 2);
				loc_540_ = rt_and_i32(loc_563_, 1);
				loc_541_ = rt_and_i32(loc_563_, 3);
				loc_542_ = bit32_or(loc_562_ + 1, 0);
				loc_543_ = bit32_or(0 - rt_and_i32(loc_563_, 2147483646), 0);
				loc_544_ = bit32_or(0 - rt_and_i32(loc_563_, 2147483644), 0);
				loc_545_ = rt_square_root_f32(rt_convert_s32_to_f32(loc_563_));
				loc_546_ = loc_564_;
				loc_547_ = 0;
				repeat
					rt_yield_budget = rt_yield_budget - 1
					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
					loc_564_ = bit32_or(loc_533_ + rt_shift_left_i32(rt_multiply_i32(loc_547_, loc_527_), 2), 0);
					loc_559_ = (rt_less_than_s32(loc_532_, 0) and 1 or 0);
					if rt_not_equal_i32(loc_559_, 0) then
						loc_548_ = loc_547_;
						loc_547_ = loc_546_;
						loc_546_ = loc_539_;
						loc_539_ = loc_536_;
						loc_536_ = loc_564_;
						loc_549_ = loc_531_;
						loc_558_ = loc_523_;
					else
						loc_549_ = loc_531_;
						loc_558_ = loc_523_;
						loc_561_ = loc_528_;
						loc_562_ = loc_535_;
						loc_563_ = loc_530_;
						loc_536_, loc_564_ = loc_564_, loc_536_;
						loc_564_, loc_547_ = loc_547_, loc_564_;
						loc_547_, loc_546_ = loc_546_, loc_547_;
						loc_546_, loc_539_ = loc_539_, loc_546_;
						loc_535_ = loc_562_;
						loc_557_ = 0;
						loc_530_ = loc_563_;
						loc_528_ = loc_561_;
						loc_548_ = loc_564_;
						loc_564_ = rt_divide_s32(loc_564_, loc_561_);
						loc_556_ = bit32_or(loc_562_ + rt_shift_left_i32(rt_multiply_i32(loc_564_, loc_563_), 2), 0);
						repeat
							rt_yield_budget = rt_yield_budget - 1
							if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
							loc_564_ = 0 --[[ 0_f32 ]];
							if rt_less_than_s32(loc_530_, 1) then
								loc_553_ = loc_538_;
								loc_554_ = loc_532_;
								loc_555_ = loc_557_;
								loc_557_ = loc_564_;
							else
								loc_553_ = loc_538_;
								loc_554_ = loc_532_;
								loc_555_ = loc_557_;
								loc_557_ = loc_564_;
								if rt_greater_than_equal_u32(loc_530_, 4) then
									loc_550_ = loc_539_;
									loc_539_ = loc_550_;
									loc_551_ = loc_556_;
									loc_552_ = 0;
									repeat
										rt_yield_budget = rt_yield_budget - 1
										if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
										loc_532_ = loc_544_;
										loc_564_ = rt_load_f32(loc_525_, loc_550_, 0);
										loc_563_ = rt_load_f32(loc_525_, loc_551_, 0);
										loc_562_ = rt_load_f32(loc_525_, bit32_or(loc_550_ + 4, 0), 0);
										loc_561_ = rt_load_f32(loc_525_, bit32_or(loc_551_ + 4, 0), 0);
										loc_560_ = rt_load_f32(loc_525_, bit32_or(loc_550_ + 8, 0), 0);
										loc_523_ = rt_load_f32(loc_525_, bit32_or(loc_551_ + 8, 0), 0);
										loc_531_ = rt_load_f32(loc_525_, bit32_or(loc_550_ + 12, 0), 0);
										loc_538_ = rt_load_f32(loc_525_, bit32_or(loc_551_ + 12, 0), 0);
										loc_551_ = bit32_or(loc_551_ + 16, 0);
										loc_550_ = bit32_or(loc_550_ + 16, 0);
										loc_544_ = loc_532_;
										loc_557_ = rt_add_f32(rt_add_f32(rt_add_f32(rt_add_f32(loc_557_, rt_multiply_f32(loc_564_, loc_563_)), rt_multiply_f32(loc_562_, loc_561_)), rt_multiply_f32(loc_560_, loc_523_)), rt_multiply_f32(loc_531_, loc_538_));
										loc_538_ = bit32_or(loc_552_ + -4, 0);
										loc_552_ = loc_538_;
									until not (rt_not_equal_i32(loc_532_, loc_538_))
									loc_552_ = bit32_or(0 - loc_552_, 0);
								else
									loc_550_ = loc_539_;
									loc_539_ = loc_550_;
									loc_552_ = 0;
								end
								if not (rt_equal_i32(loc_541_, 0)) then
									loc_552_ = rt_shift_left_i32(loc_552_, 2);
									loc_551_ = loc_541_;
									repeat
										rt_yield_budget = rt_yield_budget - 1
										if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
										loc_532_ = rt_load_f32(loc_525_, bit32_or(loc_539_ + loc_552_, 0), 0);
										loc_538_ = rt_load_f32(loc_525_, bit32_or(loc_556_ + loc_552_, 0), 0);
										loc_552_ = bit32_or(loc_552_ + 4, 0);
										loc_550_ = bit32_or(loc_551_ + -1, 0);
										loc_551_ = loc_550_;
										loc_557_ = rt_add_f32(loc_557_, rt_multiply_f32(loc_532_, loc_538_));
									until loc_550_ == 0
								end
							end
							rt_store_f32(loc_525_, bit32_or(loc_536_ + rt_shift_left_i32(loc_555_, 2), 0), 0, rt_divide_f32(loc_557_, loc_545_))
							loc_557_ = bit32_or(loc_555_ + 1, 0);
							loc_532_ = loc_554_;
							loc_538_ = loc_553_;
							loc_556_ = bit32_or(loc_556_ + loc_553_, 0);
						until not (rt_not_equal_i32(loc_555_, loc_554_))
					end
					loc_557_ = buffer_read_i32(loc_525_[1], 0, 10932);
					if not (rt_equal_i32(loc_557_, 0)) then
						loc_557_ = rt_table_get_function(loc_524_, loc_557_, "i32,i32->");
						loc_557_(9, 0, loc_558_)
					end
					loc_526_[1](loc_536_, loc_542_, loc_558_)
					loc_558_ = buffer_read_i32(loc_525_[1], 0, 10932);
					if not (rt_equal_i32(loc_558_, 0)) then
						loc_557_ = rt_table_get_function(loc_524_, loc_558_, "i32,i32->");
						loc_558_ = loc_523_;
						loc_557_(9, 1, loc_558_)
					end
					loc_531_ = bit32_or(loc_537_ + rt_shift_left_i32(rt_multiply_i32(loc_548_, loc_530_), 2), 0);
					if not (rt_equal_i32(loc_546_, 0)) then
						rt_memory_fill(loc_525_, loc_531_, 0, loc_546_)
					end
					if not (rt_not_equal_i32(loc_559_, 0)) then
						loc_554_ = loc_536_;
						loc_555_ = loc_528_;
						loc_556_ = loc_534_;
						loc_557_ = loc_530_;
						loc_558_ = loc_531_;
						loc_559_ = loc_548_;
						loc_534_ = loc_556_;
						loc_536_ = 0;
						loc_530_ = loc_557_;
						loc_528_ = loc_555_;
						loc_548_ = loc_559_;
						loc_531_ = loc_554_;
						loc_559_ = rt_divide_s32(loc_559_, loc_555_);
						loc_552_ = bit32_or(loc_556_ + rt_shift_left_i32(rt_multiply_i32(loc_559_, loc_557_), 2), 0);
						loc_550_ = loc_552_;
						loc_551_ = loc_558_;
						repeat
							rt_yield_budget = rt_yield_budget - 1
							if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
							if rt_less_than_s32(loc_530_, 1) then
								loc_553_ = loc_536_;
								loc_554_ = loc_532_;
								loc_555_ = loc_538_;
							else
								loc_553_ = loc_536_;
								loc_554_ = loc_532_;
								loc_555_ = loc_538_;
								loc_536_ = rt_load_f32(loc_525_, bit32_or(loc_531_ + rt_shift_left_i32(loc_553_, 2), 0), 0);
								loc_538_ = 0;
								if not (rt_equal_i32(loc_530_, 1)) then
									loc_559_ = loc_538_;
									loc_538_ = loc_547_;
									loc_532_ = loc_550_;
									loc_556_ = 0;
									repeat
										rt_yield_budget = rt_yield_budget - 1
										if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
										loc_558_ = loc_543_;
										loc_557_ = rt_load_f32(loc_525_, loc_538_, 0);
										loc_559_ = rt_load_f32(loc_525_, loc_532_, 0);
										rt_store_f32(loc_525_, loc_538_, 0, rt_add_f32(loc_557_, rt_multiply_f32(loc_536_, loc_559_)))
										loc_559_ = bit32_or(loc_538_ + 4, 0);
										loc_543_ = rt_load_f32(loc_525_, loc_559_, 0);
										loc_557_ = rt_load_f32(loc_525_, bit32_or(loc_532_ + 4, 0), 0);
										rt_store_f32(loc_525_, loc_559_, 0, rt_add_f32(loc_543_, rt_multiply_f32(loc_536_, loc_557_)))
										loc_538_ = bit32_or(loc_538_ + 8, 0);
										loc_532_ = bit32_or(loc_532_ + 8, 0);
										loc_543_ = loc_558_;
										loc_557_ = bit32_or(loc_556_ + -2, 0);
										loc_556_ = loc_557_;
									until not (rt_not_equal_i32(loc_558_, loc_557_))
									loc_538_ = bit32_or(0 - loc_556_, 0);
								end
								if not (rt_equal_i32(loc_540_, 0)) then
									loc_538_ = rt_shift_left_i32(loc_538_, 2);
									loc_556_ = bit32_or(loc_551_ + loc_538_, 0);
									loc_532_ = rt_load_f32(loc_525_, loc_556_, 0);
									loc_538_ = rt_load_f32(loc_525_, bit32_or(bit32_or(loc_552_ + rt_shift_left_i32(rt_multiply_i32(loc_553_, loc_529_), 2), 0) + loc_538_, 0), 0);
									rt_store_f32(loc_525_, loc_556_, 0, rt_add_f32(loc_532_, rt_multiply_f32(loc_536_, loc_538_)))
								end
							end
							loc_536_ = bit32_or(loc_553_ + 1, 0);
							loc_532_ = loc_554_;
							loc_538_ = loc_555_;
							loc_550_ = bit32_or(loc_550_ + loc_555_, 0);
						until not (rt_not_equal_i32(loc_553_, loc_554_))
					end
					loc_536_ = bit32_or(loc_539_ + loc_546_, 0);
					loc_531_ = loc_549_;
					loc_539_ = loc_546_;
					loc_546_ = bit32_or(loc_547_ + loc_546_, 0);
					loc_548_ = bit32_or(loc_548_ + 1, 0);
					loc_547_ = loc_548_;
				until not (rt_not_equal_i32(loc_548_, loc_549_))
			end
			return loc_523_
		end), "i32,i32,i32,i32,i32,i32,i32,i32,i32,i32,i32,i32->")
	end)(module_locals[59], module_locals[162], module_locals[3]);
	do (function() --[[spider:chunk]]
	module_locals[56][1] = (function(loc_565_)
		return rt_function_type(--[[fn:k_residual]](function(loc_566_, loc_567_, loc_568_, loc_569_)
			local loc_570_, loc_571_, loc_572_, loc_573_, loc_574_, loc_575_, loc_576_, loc_577_, loc_578_, loc_579_, loc_580_, loc_581_, loc_582_
			if rt_less_than_s32(loc_568_, 1) then
				loc_570_ = loc_569_;
				loc_571_ = loc_565_;
				loc_572_ = loc_566_;
				loc_573_ = loc_567_;
				loc_574_ = loc_568_;
			else
				loc_570_ = loc_569_;
				loc_571_ = loc_565_;
				loc_572_ = loc_566_;
				loc_573_ = loc_567_;
				loc_574_ = loc_568_;
				loc_582_ = rt_and_i32(loc_574_, 3);
				loc_575_ = 0;
				if rt_less_than_u32(loc_574_, 4) then
					loc_576_ = loc_574_;
					loc_574_ = loc_572_;
					loc_572_ = loc_582_;
				else
					loc_576_ = loc_574_;
					loc_574_ = loc_572_;
					loc_572_ = loc_582_;
					loc_582_ = loc_575_;
					loc_575_ = 0;
					loc_576_ = rt_and_i32(loc_576_, 2147483644);
					loc_577_ = 0;
					repeat
						rt_yield_budget = rt_yield_budget - 1
						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
						loc_579_ = loc_576_;
						loc_580_ = bit32_or(loc_573_ + loc_577_, 0);
						loc_581_ = rt_load_f32(loc_571_, loc_580_, 0);
						loc_578_ = bit32_or(loc_574_ + loc_577_, 0);
						loc_582_ = rt_load_f32(loc_571_, loc_578_, 0);
						rt_store_f32(loc_571_, loc_578_, 0, rt_add_f32(loc_581_, loc_582_))
						loc_576_ = rt_load_f32(loc_571_, bit32_or(loc_580_ + 4, 0), 0);
						loc_581_ = bit32_or(loc_578_ + 4, 0);
						loc_582_ = rt_load_f32(loc_571_, loc_581_, 0);
						rt_store_f32(loc_571_, loc_581_, 0, rt_add_f32(loc_576_, loc_582_))
						loc_582_ = rt_load_f32(loc_571_, bit32_or(loc_580_ + 8, 0), 0);
						loc_581_ = bit32_or(loc_578_ + 8, 0);
						loc_576_ = rt_load_f32(loc_571_, loc_581_, 0);
						rt_store_f32(loc_571_, loc_581_, 0, rt_add_f32(loc_582_, loc_576_))
						loc_580_ = rt_load_f32(loc_571_, bit32_or(loc_580_ + 12, 0), 0);
						loc_576_ = bit32_or(loc_578_ + 12, 0);
						loc_578_ = rt_load_f32(loc_571_, loc_576_, 0);
						rt_store_f32(loc_571_, loc_576_, 0, rt_add_f32(loc_580_, loc_578_))
						loc_578_ = bit32_or(loc_575_ + 4, 0);
						loc_575_ = loc_578_;
						loc_576_ = loc_579_;
						loc_577_ = bit32_or(loc_577_ + 16, 0);
					until not (rt_not_equal_i32(loc_579_, loc_578_))
				end
				if not (rt_equal_i32(loc_572_, 0)) then
					loc_576_ = rt_shift_left_i32(loc_575_, 2);
					loc_575_ = bit32_or(loc_574_ + loc_576_, 0);
					loc_574_ = loc_572_;
					loc_573_ = bit32_or(loc_573_ + loc_576_, 0);
					repeat
						rt_yield_budget = rt_yield_budget - 1
						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
						loc_576_ = rt_load_f32(loc_571_, loc_573_, 0);
						loc_572_ = rt_load_f32(loc_571_, loc_575_, 0);
						rt_store_f32(loc_571_, loc_575_, 0, rt_add_f32(loc_576_, loc_572_))
						loc_575_ = bit32_or(loc_575_ + 4, 0);
						loc_572_ = bit32_or(loc_574_ + -1, 0);
						loc_574_ = loc_572_;
						loc_573_ = bit32_or(loc_573_ + 4, 0);
					until loc_572_ == 0
				end
			end
			return loc_570_
		end), "i32,i32,i32->")
	end)(module_locals[3]);
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[57][1] = (function(loc_583_, loc_584_)
		return rt_function_type(--[[fn:k_silu_mul]](function(loc_585_, loc_586_, loc_587_, loc_588_)
			local loc_589_, loc_590_, loc_591_, loc_592_, loc_593_, loc_594_, loc_595_, loc_596_, loc_597_
			if rt_less_than_s32(loc_587_, 1) then
				loc_589_ = loc_588_;
				loc_590_ = loc_584_;
				loc_591_ = loc_583_;
				loc_592_ = loc_585_;
				loc_593_ = loc_586_;
				loc_594_ = loc_587_;
			else
				loc_589_ = loc_588_;
				loc_590_ = loc_584_;
				loc_591_ = loc_583_;
				loc_592_ = loc_585_;
				loc_593_ = loc_586_;
				loc_597_ = loc_587_;
				loc_594_ = loc_592_;
				loc_592_ = loc_597_;
				repeat
					rt_yield_budget = rt_yield_budget - 1
					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
					loc_595_ = loc_591_;
					loc_591_ = loc_595_;
					loc_597_ = rt_load_f32(loc_590_, loc_594_, 0);
					loc_596_ = loc_589_;
					loc_596_ = loc_595_[1](rt_negate_f32(loc_597_), loc_596_)
					loc_595_ = rt_load_f32(loc_590_, loc_593_, 0);
					rt_store_f32(loc_590_, loc_594_, 0, rt_multiply_f32(loc_595_, rt_multiply_f32(loc_597_, rt_divide_f32(1e0 --[[ 1_f32 ]], rt_add_f32(loc_596_, 1e0 --[[ 1_f32 ]])))))
					loc_594_ = bit32_or(loc_594_ + 4, 0);
					loc_593_ = bit32_or(loc_593_ + 4, 0);
					loc_595_ = bit32_or(loc_592_ + -1, 0);
					loc_592_ = loc_595_;
				until loc_595_ == 0
			end
			return loc_589_
		end), "i32,i32,i32->")
	end)(module_locals[36], module_locals[3]);
	end)() end --[[/spider:chunk]]
	module_locals[58][1] = (function(loc_598_)
		return rt_function_type(--[[fn:matmul]](function(loc_599_, loc_600_, loc_601_, loc_602_, loc_603_, loc_604_, loc_605_)
			local loc_606_, loc_607_, loc_608_, loc_609_, loc_610_, loc_611_, loc_612_, loc_613_, loc_614_, loc_615_, loc_616_, loc_617_, loc_618_, loc_619_, loc_620_, loc_621_, loc_622_, loc_623_, loc_624_, loc_625_, loc_626_, loc_627_, loc_628_, loc_629_, loc_630_, loc_631_
			if rt_less_than_s32(loc_602_, 1) then
				loc_606_ = loc_605_;
				loc_607_ = loc_598_;
				loc_608_ = loc_599_;
				loc_609_ = loc_600_;
				loc_610_ = loc_601_;
				loc_611_ = loc_602_;
				loc_612_ = loc_603_;
				loc_613_ = loc_604_;
			else
				loc_606_ = loc_605_;
				loc_607_ = loc_598_;
				loc_608_ = loc_599_;
				loc_609_ = loc_600_;
				loc_610_ = loc_601_;
				loc_611_ = loc_602_;
				loc_612_ = loc_603_;
				loc_613_ = loc_604_;
				loc_630_ = buffer_read_i32(loc_607_[1], loc_609_, 0);
				loc_631_ = rt_and_i32(loc_611_, 3);
				loc_629_ = 0;
				if not (rt_less_than_u32(loc_611_, 4)) then
					loc_628_ = loc_611_;
					loc_611_ = loc_628_;
					loc_629_ = 0;
					loc_628_ = rt_and_i32(loc_628_, 2147483644);
					loc_627_ = 10944;
					repeat
						rt_yield_budget = rt_yield_budget - 1
						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
						loc_625_ = loc_628_;
						loc_628_ = bit32_or(loc_630_ + loc_629_, 0);
						loc_626_ = rt_load_i32_from_s8(loc_607_, loc_628_, 0);
						rt_store_i32(loc_607_, loc_627_, 0, loc_626_)
						loc_626_ = rt_load_i32_from_s8(loc_607_, bit32_or(loc_628_ + 1, 0), 0);
						rt_store_i32(loc_607_, bit32_or(loc_627_ + 4, 0), 0, loc_626_)
						loc_626_ = rt_load_i32_from_s8(loc_607_, bit32_or(loc_628_ + 2, 0), 0);
						rt_store_i32(loc_607_, bit32_or(loc_627_ + 8, 0), 0, loc_626_)
						loc_628_ = rt_load_i32_from_s8(loc_607_, bit32_or(loc_628_ + 3, 0), 0);
						rt_store_i32(loc_607_, bit32_or(loc_627_ + 12, 0), 0, loc_628_)
						loc_626_ = bit32_or(loc_629_ + 4, 0);
						loc_629_ = loc_626_;
						loc_628_ = loc_625_;
						loc_627_ = bit32_or(loc_627_ + 16, 0);
					until not (rt_not_equal_i32(loc_625_, loc_626_))
				end
				if not (rt_equal_i32(loc_631_, 0)) then
					loc_630_ = bit32_or(loc_630_ + loc_629_, 0);
					loc_629_ = bit32_or(rt_shift_left_i32(loc_629_, 2) + 10944, 0);
					repeat
						rt_yield_budget = rt_yield_budget - 1
						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
						loc_628_ = rt_load_i32_from_s8(loc_607_, loc_630_, 0);
						rt_store_i32(loc_607_, loc_629_, 0, loc_628_)
						loc_628_ = bit32_or(loc_631_ + -1, 0);
						loc_631_ = loc_628_;
						loc_630_ = bit32_or(loc_630_ + 1, 0);
						loc_629_ = bit32_or(loc_629_ + 4, 0);
					until loc_628_ == 0
				end
			end
			loc_614_ = rt_divide_s32(loc_611_, loc_613_);
			loc_631_ = loc_614_;
			if not (rt_less_than_s32(loc_612_, 1)) then
				loc_629_ = loc_612_;
				loc_630_ = loc_613_;
				loc_631_ = loc_614_;
				loc_615_ = buffer_read_i32(loc_607_[1], loc_609_, 4);
				loc_616_ = buffer_read_i32(loc_607_[1], loc_610_, 0);
				loc_613_ = buffer_read_i32(loc_607_[1], loc_610_, 4);
				loc_614_ = loc_608_;
				loc_612_ = loc_611_;
				loc_611_ = loc_629_;
				loc_610_ = loc_630_;
				loc_609_ = loc_631_;
				loc_608_ = rt_shift_left_i32(loc_630_, 2);
				loc_617_ = 0;
				loc_618_ = (rt_less_than_s32(loc_631_, 1) and 1 or 0);
				repeat
					rt_yield_budget = rt_yield_budget - 1
					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
					if rt_equal_i32(loc_618_, 0) then
						loc_619_ = loc_617_;
						loc_617_ = loc_613_;
						loc_620_ = loc_611_;
						loc_631_ = loc_612_;
						loc_611_ = 10944;
						loc_612_ = loc_631_;
						loc_621_ = bit32_or(loc_616_ + rt_multiply_i32(loc_619_, loc_631_), 0);
						loc_622_ = 0;
						loc_613_ = 0 --[[ 0_f32 ]];
						repeat
							rt_yield_budget = rt_yield_budget - 1
							if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
							loc_626_ = 0 --[[ 0_f32 ]];
							if rt_less_than_s32(loc_610_, 1) then
								loc_623_ = loc_622_;
								loc_622_ = loc_621_;
								loc_621_ = loc_610_;
								loc_624_ = loc_609_;
								loc_627_ = loc_613_;
							else
								loc_623_ = loc_622_;
								loc_622_ = loc_621_;
								loc_621_ = loc_610_;
								loc_624_ = loc_609_;
								loc_627_ = loc_613_;
								loc_630_ = loc_626_;
								loc_631_ = loc_611_;
								loc_611_ = loc_631_;
								loc_626_ = 0;
								loc_625_ = 0;
								loc_613_ = loc_631_;
								repeat
									rt_yield_budget = rt_yield_budget - 1
									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
									loc_609_ = loc_621_;
									loc_631_ = buffer_read_i32(loc_607_[1], bit32_or(loc_613_ + 4, 0), 0);
									loc_630_ = buffer_read_i32(loc_607_[1], bit32_or(loc_622_ + loc_625_, 0), 0);
									loc_629_ = buffer_read_i32(loc_607_[1], loc_613_, 0);
									loc_628_ = buffer_read_i32(loc_607_[1], bit32_or(loc_613_ + 8, 0), 0);
									loc_610_ = buffer_read_i32(loc_607_[1], bit32_or(loc_613_ + 12, 0), 0);
									loc_621_ = loc_609_;
									loc_626_ = bit32_or(bit32_or(bit32_or(bit32_or(rt_multiply_i32(loc_631_, rt_shift_right_s32(rt_shift_left_i32(loc_630_, 16), 24)) + loc_626_, 0) + rt_multiply_i32(rt_extend_s8_to_i32(loc_630_), loc_629_), 0) + rt_multiply_i32(loc_628_, rt_shift_right_s32(rt_shift_left_i32(loc_630_, 8), 24)), 0) + rt_multiply_i32(loc_610_, rt_shift_right_s32(loc_630_, 24)), 0);
									loc_610_ = bit32_or(loc_625_ + 4, 0);
									loc_625_ = loc_610_;
									loc_613_ = bit32_or(loc_613_ + 16, 0);
								until not (rt_less_than_s32(loc_610_, loc_609_))
								loc_626_ = rt_convert_s32_to_f32(loc_626_);
							end
							loc_613_ = rt_shift_left_i32(loc_623_, 2);
							loc_625_ = rt_load_f32(loc_607_, bit32_or(loc_617_ + loc_613_, 0), 0);
							loc_613_ = rt_load_f32(loc_607_, bit32_or(loc_615_ + loc_613_, 0), 0);
							loc_611_ = bit32_or(loc_611_ + loc_608_, 0);
							loc_610_ = loc_621_;
							loc_621_ = bit32_or(loc_622_ + loc_621_, 0);
							loc_623_ = bit32_or(loc_623_ + 1, 0);
							loc_622_ = loc_623_;
							loc_609_ = loc_624_;
							loc_613_ = rt_add_f32(loc_627_, rt_multiply_f32(rt_multiply_f32(loc_625_, loc_626_), loc_613_));
						until not (rt_not_equal_i32(loc_623_, loc_624_))
					else
						loc_619_ = loc_617_;
						loc_617_ = loc_613_;
						loc_620_ = loc_611_;
						loc_631_ = loc_612_;
						loc_612_ = loc_631_;
						loc_613_ = 0 --[[ 0_f32 ]];
					end
					rt_store_f32(loc_607_, bit32_or(loc_614_ + rt_shift_left_i32(loc_619_, 2), 0), 0, loc_613_)
					loc_613_ = bit32_or(loc_617_ + rt_shift_left_i32(loc_609_, 2), 0);
					loc_611_ = loc_620_;
					loc_619_ = bit32_or(loc_619_ + 1, 0);
					loc_617_ = loc_619_;
				until not (rt_not_equal_i32(loc_619_, loc_620_))
			end
			return loc_606_
		end), "i32,i32,i32,i32,i32,i32->")
	end)(module_locals[3]);
	do (function() --[[spider:chunk]]
	module_locals[59][1] = (function(loc_632_, loc_633_)
		return rt_function_type(--[[fn:k_softmax]](function(loc_634_, loc_635_, loc_636_)
			local loc_637_, loc_638_, loc_639_, loc_640_, loc_641_, loc_642_, loc_643_, loc_644_, loc_645_, loc_646_, loc_647_, loc_648_, loc_649_, loc_650_, loc_651_, loc_652_, loc_653_
			loc_642_ = rt_load_f32(loc_633_, loc_634_, 0);
			loc_638_ = loc_633_;
			if rt_less_than_s32(loc_635_, 2) then
				loc_637_ = loc_636_;
				loc_639_ = loc_632_;
				loc_640_ = loc_634_;
				loc_641_ = loc_635_;
				if rt_equal_i32(loc_641_, 1) then
					loc_647_ = 0;
				else
					loc_647_ = 1;
				end
			else
				loc_637_ = loc_636_;
				loc_639_ = loc_632_;
				loc_640_ = loc_634_;
				loc_641_ = loc_635_;
				loc_653_ = bit32_or(loc_641_ + -1, 0);
				loc_647_ = rt_and_i32(loc_653_, 3);
				if rt_greater_than_equal_u32(bit32_or(loc_641_ + -2, 0), 3) then
					loc_652_ = loc_640_;
					loc_640_ = loc_652_;
					loc_646_ = 0;
					loc_645_ = bit32_or(loc_652_ + 16, 0);
					loc_644_ = rt_and_i32(loc_653_, -4);
					repeat
						rt_yield_budget = rt_yield_budget - 1
						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
						loc_652_ = loc_642_;
						loc_642_ = rt_load_f32(loc_638_, loc_645_, 0);
						loc_653_ = rt_load_f32(loc_638_, bit32_or(loc_645_ + -4, 0), 0);
						loc_649_ = rt_load_f32(loc_638_, bit32_or(loc_645_ + -8, 0), 0);
						loc_651_ = rt_load_f32(loc_638_, bit32_or(loc_645_ + -12, 0), 0);
						if rt_greater_than_f32(loc_651_, loc_652_) then
							loc_643_ = loc_642_;
							loc_648_ = loc_644_;
							loc_644_ = loc_653_;
							loc_650_ = loc_653_;
							loc_653_ = loc_652_;
							loc_652_ = loc_649_;
						else
							loc_643_ = loc_642_;
							loc_648_ = loc_644_;
							loc_644_ = loc_653_;
							loc_650_ = loc_653_;
							loc_653_ = loc_652_;
							loc_652_ = loc_649_;
							loc_651_ = loc_653_;
						end
						if not (rt_greater_than_f32(loc_652_, loc_651_)) then
							loc_649_ = loc_651_;
						end
						if not (rt_greater_than_f32(loc_650_, loc_649_)) then
							loc_644_ = loc_649_;
						end
						if not (rt_greater_than_f32(loc_643_, loc_644_)) then
							loc_643_ = loc_642_;
							loc_642_ = loc_644_;
						end
						loc_643_ = bit32_or(loc_646_ + 4, 0);
						loc_646_ = loc_643_;
						loc_645_ = bit32_or(loc_645_ + 16, 0);
						loc_644_ = loc_648_;
					until not (rt_not_equal_i32(loc_648_, loc_643_))
					loc_646_ = bit32_or(loc_646_ + 1, 0);
				else
					loc_652_ = loc_640_;
					loc_640_ = loc_652_;
					loc_646_ = 1;
				end
				if rt_equal_i32(loc_647_, 0) then
					loc_647_ = 0;
				else
					loc_645_ = loc_640_;
					loc_640_ = loc_645_;
					loc_646_ = bit32_or(loc_645_ + rt_shift_left_i32(loc_646_, 2), 0);
					repeat
						rt_yield_budget = rt_yield_budget - 1
						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
						loc_645_ = loc_642_;
						loc_642_ = rt_load_f32(loc_638_, loc_646_, 0);
						if not (rt_greater_than_f32(loc_642_, loc_645_)) then
							loc_644_ = loc_642_;
							loc_642_ = loc_645_;
						end
						loc_645_ = bit32_or(loc_647_ + -1, 0);
						loc_647_ = loc_645_;
						loc_646_ = bit32_or(loc_646_ + 4, 0);
					until loc_645_ == 0
					loc_647_ = 0;
				end
			end
			if rt_not_equal_i32(loc_647_, 0) then
				loc_640_ = 0;
			else
				loc_647_ = loc_642_;
				loc_642_ = loc_640_;
				loc_644_ = loc_641_;
				loc_646_ = loc_641_;
				loc_645_ = loc_640_;
				loc_640_ = 0 --[[ 0_f32 ]];
				repeat
					rt_yield_budget = rt_yield_budget - 1
					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
					loc_643_ = loc_637_;
					loc_637_ = loc_639_;
					loc_639_ = loc_637_;
					loc_641_ = rt_load_f32(loc_638_, loc_645_, 0);
					loc_641_ = loc_637_[1](rt_subtract_f32(loc_641_, loc_647_), loc_643_)
					rt_store_f32(loc_638_, loc_645_, 0, loc_641_)
					loc_643_ = bit32_or(loc_646_ + -1, 0);
					loc_646_ = loc_643_;
					loc_645_ = bit32_or(loc_645_ + 4, 0);
					loc_640_ = rt_add_f32(loc_640_, loc_641_);
				until loc_643_ == 0
				loc_641_ = 0;
				loc_643_ = rt_and_i32(loc_644_, 1);
				if not (rt_equal_i32(loc_644_, 1)) then
					loc_645_ = loc_641_;
					loc_646_ = loc_642_;
					loc_647_ = loc_644_;
					loc_642_ = loc_646_;
					loc_641_ = 0;
					loc_644_ = loc_646_;
					loc_645_ = rt_and_i32(loc_647_, -2);
					repeat
						rt_yield_budget = rt_yield_budget - 1
						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
						loc_647_ = loc_645_;
						loc_646_ = rt_load_f32(loc_638_, loc_644_, 0);
						rt_store_f32(loc_638_, loc_644_, 0, rt_divide_f32(loc_646_, loc_640_))
						loc_645_ = bit32_or(loc_644_ + 4, 0);
						loc_646_ = rt_load_f32(loc_638_, loc_645_, 0);
						rt_store_f32(loc_638_, loc_645_, 0, rt_divide_f32(loc_646_, loc_640_))
						loc_646_ = bit32_or(loc_641_ + 2, 0);
						loc_641_ = loc_646_;
						loc_644_ = bit32_or(loc_644_ + 8, 0);
						loc_645_ = loc_647_;
					until not (rt_not_equal_i32(loc_647_, loc_646_))
				end
				if rt_equal_i32(loc_643_, 0) then
					loc_640_ = 0;
				else
					loc_641_ = bit32_or(loc_642_ + rt_shift_left_i32(loc_641_, 2), 0);
					loc_642_ = rt_load_f32(loc_638_, loc_641_, 0);
					rt_store_f32(loc_638_, loc_641_, 0, rt_divide_f32(loc_642_, loc_640_))
					loc_640_ = 1;
				end
			end
			if rt_not_equal_i32(loc_640_, 0) then
			end
			return loc_637_
		end), "i32,i32->")
	end)(module_locals[36], module_locals[3]);
	module_locals[60] = { nil };
	module_locals[61] = { nil };
	end)() end --[[/spider:chunk]]
	module_locals[60][1] = (function(loc_654_, loc_655_, loc_656_, loc_657_, loc_658_, loc_659_, loc_660_, loc_661_, loc_662_, loc_663_, loc_664_, loc_665_, loc_666_)
		return rt_function_type(--[[fn:model_forward_batch]](function(loc_667_, loc_668_, loc_669_, loc_670_, loc_671_)
			local loc_672_, loc_673_, loc_674_, loc_675_, loc_676_, loc_677_, loc_678_, loc_679_, loc_680_, loc_681_, loc_682_, loc_683_, loc_684_, loc_685_, loc_686_, loc_687_, loc_688_, loc_689_, loc_690_, loc_691_, loc_692_, loc_693_, loc_694_, loc_695_, loc_696_, loc_697_, loc_698_, loc_699_, loc_700_, loc_701_, loc_702_, loc_703_, loc_704_, loc_705_, loc_706_, loc_707_, loc_708_, loc_709_, loc_710_, loc_711_, loc_712_, loc_713_, loc_714_, loc_715_, loc_716_, loc_717_, loc_718_, loc_719_, loc_720_, loc_721_, loc_722_, loc_723_, loc_724_
			loc_724_ = loc_664_[1];
			loc_674_ = loc_664_;
			loc_677_ = bit32_or(loc_724_ - 16, 0);
			loc_674_[1] = loc_677_;
			loc_692_ = 0;
			loc_693_ = 0;
			loc_673_ = 0;
			if rt_greater_than_equal_s32(loc_669_, 1) then
				loc_672_ = loc_671_;
				loc_675_ = loc_665_;
				loc_676_ = loc_666_;
				loc_678_ = loc_654_;
				loc_679_ = loc_655_;
				loc_680_ = loc_656_;
				loc_681_ = loc_657_;
				loc_682_ = loc_658_;
				loc_683_ = loc_659_;
				loc_684_ = loc_660_;
				loc_685_ = loc_661_;
				loc_686_ = loc_662_;
				loc_687_ = loc_663_;
				loc_688_ = loc_667_;
				loc_689_ = loc_668_;
				loc_690_ = loc_669_;
				loc_691_ = loc_670_;
				if rt_equal_i32(loc_690_, 1) then
					loc_692_ = 0;
				else
					if rt_less_than_u32(loc_690_, 17) then
						loc_694_ = loc_672_;
						loc_722_ = loc_690_;
						loc_723_ = loc_673_;
						loc_724_ = loc_689_;
						loc_692_, loc_693_ = loc_693_, loc_692_;
						loc_689_ = buffer_read_i32(loc_676_[1], loc_688_, 4);
						loc_695_ = buffer_read_i32(loc_676_[1], loc_688_, 204);
						loc_721_ = buffer_read_i32(loc_676_[1], loc_688_, 0);
						loc_718_ = buffer_read_i32(loc_676_[1], loc_688_, 12);
						loc_719_ = buffer_read_i32(loc_676_[1], loc_688_, 16);
						loc_720_ = buffer_read_i32(loc_676_[1], 0, 10932);
						loc_673_ = rt_divide_s32(loc_689_, loc_695_);
						loc_672_ = rt_divide_s32(loc_721_, loc_695_);
						loc_723_ = 0;
						loc_697_ = rt_divide_s32(loc_718_, loc_719_);
						loc_698_ = rt_divide_s32(loc_721_, loc_718_);
						loc_699_ = rt_divide_s32(loc_698_, 2);
						loc_700_ = rt_divide_s32(rt_multiply_i32(loc_719_, loc_721_), loc_718_);
						loc_719_ = loc_673_;
						loc_719_ = loc_672_;
						loc_719_ = loc_697_;
						loc_719_ = loc_698_;
						loc_719_ = loc_699_;
						loc_719_ = loc_700_;
						if not (rt_equal_i32(loc_720_, 0)) then
							loc_719_ = rt_table_get_function(loc_675_, loc_720_, "i32,i32->");
							loc_720_ = loc_694_;
							loc_719_(0, 0, loc_720_)
						end
						loc_690_ = loc_722_;
						loc_696_ = loc_721_;
						loc_721_ = rt_shift_left_i32(loc_721_, 2);
						repeat
							rt_yield_budget = rt_yield_budget - 1
							if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
							loc_716_ = loc_679_;
							loc_679_ = loc_716_;
							loc_717_ = buffer_read_i32(loc_676_[1], loc_688_, 132);
							loc_718_ = buffer_read_i32(loc_676_[1], loc_688_, 28);
							loc_719_ = buffer_read_i32(loc_676_[1], loc_724_, 0);
							loc_720_ = loc_694_;
							loc_716_[1](bit32_or(loc_717_ + loc_723_, 0), loc_718_, loc_719_, loc_696_, loc_695_, loc_720_)
							loc_724_ = bit32_or(loc_724_ + 4, 0);
							loc_723_ = bit32_or(loc_723_ + loc_721_, 0);
							loc_720_ = bit32_or(loc_722_ + -1, 0);
							loc_722_ = loc_720_;
						until loc_720_ == 0
						loc_724_ = buffer_read_i32(loc_676_[1], 0, 10932);
						if not (rt_equal_i32(loc_724_, 0)) then
							loc_723_ = rt_table_get_function(loc_675_, loc_724_, "i32,i32->");
							loc_724_ = loc_694_;
							loc_723_(0, 1, loc_724_)
						end
						loc_724_ = buffer_read_i32(loc_676_[1], loc_688_, 8);
						if not (rt_less_than_s32(loc_724_, 1)) then
							loc_714_ = loc_696_;
							loc_715_ = loc_697_;
							loc_716_ = loc_698_;
							loc_717_ = loc_689_;
							loc_718_ = loc_673_;
							loc_719_ = loc_690_;
							loc_720_ = loc_672_;
							loc_721_ = loc_688_;
							loc_722_ = loc_700_;
							loc_723_ = loc_691_;
							loc_724_ = loc_699_;
							loc_700_ = loc_693_;
							loc_699_ = loc_692_;
							loc_688_ = loc_721_;
							loc_690_ = loc_719_;
							loc_691_ = loc_723_;
							loc_696_ = loc_714_;
							loc_698_ = loc_717_;
							loc_697_ = rt_shift_left_i32(loc_722_, 2);
							loc_693_ = rt_shift_left_i32(loc_714_, 2);
							loc_692_ = loc_715_;
							loc_689_ = loc_716_;
							loc_673_ = loc_722_;
							loc_672_ = rt_shift_left_i32(loc_717_, 2);
							loc_701_ = rt_shift_left_i32(loc_718_, 2);
							loc_702_ = bit32_or(loc_719_ + -1, 0);
							loc_703_ = rt_shift_left_i32(loc_724_, 2);
							loc_704_ = rt_shift_left_i32(loc_720_, 2);
							loc_705_ = bit32_or(loc_721_ + 172, 0);
							loc_706_ = bit32_or(loc_721_ + 164, 0);
							loc_707_ = rt_shift_left_i32(rt_multiply_i32(loc_722_, loc_723_), 2);
							loc_708_ = rt_shift_left_i32(rt_multiply_i32(loc_724_, loc_723_), 2);
							loc_709_ = 0;
							loc_710_ = 0;
							repeat
								rt_yield_budget = rt_yield_budget - 1
								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
								loc_723_ = loc_696_;
								loc_724_ = loc_709_;
								loc_722_ = buffer_read_i32(loc_676_[1], 0, 10932);
								loc_721_ = 0;
								loc_718_ = loc_690_;
								loc_696_ = loc_723_;
								loc_720_ = 0;
								loc_709_ = loc_697_;
								loc_719_ = loc_722_;
								loc_697_ = loc_673_;
								loc_714_ = loc_707_;
								loc_716_ = loc_724_;
								loc_724_ = loc_710_;
								loc_715_ = rt_shift_left_i32(rt_multiply_i32(loc_710_, loc_723_), 2);
								loc_717_ = 0;
								loc_713_ = loc_690_;
								loc_723_ = loc_694_;
								repeat
									rt_yield_budget = rt_yield_budget - 1
									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
									loc_712_ = 0;
									loc_707_ = 0;
									if rt_equal_i32(loc_719_, 0) then
										loc_710_ = loc_719_;
										loc_711_ = loc_696_;
										loc_719_ = loc_712_;
										loc_712_ = loc_704_;
									else
										loc_710_ = loc_719_;
										loc_711_ = loc_696_;
										loc_719_ = loc_722_;
										loc_722_ = loc_712_;
										loc_712_ = loc_704_;
										loc_722_ = rt_table_get_function(loc_675_, loc_710_, "i32,i32->");
										loc_722_(1, 0, loc_723_)
										loc_722_ = buffer_read_i32(loc_676_[1], 0, 10932);
										loc_719_ = loc_722_;
									end
									loc_696_ = buffer_read_i32(loc_676_[1], loc_688_, 136);
									loc_704_ = buffer_read_i32(loc_676_[1], loc_688_, 132);
									loc_710_ = buffer_read_i32(loc_676_[1], loc_688_, 32);
									loc_680_[1](bit32_or(loc_696_ + loc_721_, 0), bit32_or(loc_704_ + loc_721_, 0), bit32_or(loc_710_ + loc_715_, 0), loc_711_, loc_723_)
									if not (rt_equal_i32(loc_719_, 0)) then
										loc_710_ = loc_722_;
										loc_722_ = loc_707_;
										loc_722_ = rt_table_get_function(loc_675_, loc_719_, "i32,i32->");
										loc_722_(1, 1, loc_723_)
										loc_722_ = buffer_read_i32(loc_676_[1], 0, 10932);
										loc_707_ = loc_722_;
									end
									loc_719_ = buffer_read_i32(loc_676_[1], loc_688_, 164);
									rt_store_i32(loc_676_, loc_677_, 8, bit32_or(loc_719_ + loc_720_, 0))
									loc_719_ = buffer_read_i32(loc_676_[1], loc_688_, 168);
									rt_store_i32(loc_676_, loc_677_, 12, bit32_or(loc_719_ + loc_717_, 0))
									loc_719_ = 0;
									loc_710_ = 0;
									if not (rt_equal_i32(loc_707_, 0)) then
										loc_710_, loc_722_ = loc_722_, loc_710_;
										loc_722_ = rt_table_get_function(loc_675_, loc_707_, "i32,i32->");
										loc_722_(2, 0, loc_723_)
										loc_722_ = buffer_read_i32(loc_676_[1], 0, 10932);
										loc_710_ = loc_722_;
									end
									loc_707_ = buffer_read_i32(loc_676_[1], loc_688_, 136);
									loc_681_[1](bit32_or(loc_677_ + 8, 0), bit32_or(loc_707_ + loc_721_, 0), loc_711_, loc_695_, loc_723_)
									if not (rt_equal_i32(loc_710_, 0)) then
										loc_719_, loc_722_ = loc_722_, loc_719_;
										loc_722_ = rt_table_get_function(loc_675_, loc_710_, "i32,i32->");
										loc_722_(2, 1, loc_723_)
										loc_722_ = buffer_read_i32(loc_676_[1], 0, 10932);
										loc_719_ = loc_722_;
									end
									loc_721_ = bit32_or(loc_721_ + loc_693_, 0);
									loc_696_ = loc_711_;
									loc_720_ = bit32_or(loc_720_ + loc_711_, 0);
									loc_704_ = loc_712_;
									loc_717_ = bit32_or(loc_717_ + loc_712_, 0);
									loc_712_ = bit32_or(loc_713_ + -1, 0);
									loc_713_ = loc_712_;
								until loc_712_ == 0
								if not (rt_equal_i32(loc_722_, 0)) then
									loc_722_ = rt_table_get_function(loc_675_, loc_722_, "i32,i32->");
									loc_722_(3, 0, loc_723_)
								end
								loc_721_ = buffer_read_i32(loc_676_[1], loc_688_, 152);
								loc_722_ = buffer_read_i32(loc_676_[1], loc_688_, 44);
								loc_712_ = rt_shift_left_i32(loc_724_, 3);
								loc_687_[1](loc_721_, loc_706_, bit32_or(loc_722_ + loc_712_, 0), loc_696_, loc_696_, loc_695_, loc_718_, loc_723_)
								loc_721_ = buffer_read_i32(loc_676_[1], loc_688_, 156);
								loc_722_ = buffer_read_i32(loc_676_[1], loc_688_, 48);
								loc_687_[1](loc_721_, loc_706_, bit32_or(loc_722_ + loc_712_, 0), loc_696_, loc_697_, loc_695_, loc_718_, loc_723_)
								loc_721_ = buffer_read_i32(loc_676_[1], loc_688_, 160);
								loc_722_ = buffer_read_i32(loc_676_[1], loc_688_, 52);
								loc_687_[1](loc_721_, loc_706_, bit32_or(loc_722_ + loc_712_, 0), loc_696_, loc_697_, loc_695_, loc_718_, loc_723_)
								loc_723_ = buffer_read_i32(loc_676_[1], 0, 10932);
								if not (rt_equal_i32(loc_723_, 0)) then
									loc_722_, loc_723_ = loc_723_, loc_722_;
									loc_722_ = rt_table_get_function(loc_675_, loc_722_, "i32,i32->");
									loc_722_(3, 1, loc_723_)
								end
								loc_717_ = buffer_read_i32(loc_676_[1], loc_688_, 24);
								loc_721_ = buffer_read_i32(loc_676_[1], 0, 10932);
								loc_723_ = 0;
								loc_713_ = loc_718_;
								loc_720_ = loc_708_;
								loc_719_ = 0;
								loc_673_ = loc_697_;
								loc_707_ = loc_714_;
								loc_710_ = loc_716_;
								loc_711_ = loc_724_;
								loc_724_ = rt_multiply_i32(rt_multiply_i32(loc_724_, loc_697_), loc_717_);
								loc_717_ = bit32_or(loc_714_ + rt_multiply_i32(loc_717_, loc_716_), 0);
								repeat
									rt_yield_budget = rt_yield_budget - 1
									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
									loc_697_ = buffer_read_i32(loc_676_[1], loc_688_, 156);
									loc_716_ = buffer_read_i32(loc_676_[1], loc_688_, 152);
									loc_714_ = 0;
									loc_697_ = bit32_or(loc_697_ + loc_723_, 0);
									loc_716_ = bit32_or(loc_716_ + loc_719_, 0);
									if rt_equal_i32(loc_721_, 0) then
										loc_693_, loc_716_ = loc_716_, loc_693_;
										loc_714_, loc_721_ = loc_721_, loc_714_;
									else
										loc_693_, loc_716_ = loc_716_, loc_693_;
										loc_714_, loc_721_ = loc_721_, loc_714_;
										loc_721_ = rt_table_get_function(loc_675_, loc_714_, "i32,i32->");
										loc_721_(4, 0, loc_722_)
										loc_721_ = buffer_read_i32(loc_676_[1], 0, 10932);
									end
									loc_694_ = buffer_read_i32(loc_676_[1], loc_688_, 188);
									loc_714_ = buffer_read_i32(loc_676_[1], loc_688_, 192);
									loc_683_[1](loc_693_, loc_697_, bit32_or(loc_694_ + loc_720_, 0), bit32_or(loc_714_ + loc_720_, 0), loc_696_, loc_673_, loc_689_, loc_722_)
									if rt_not_equal_i32(loc_721_, 0) then
										loc_721_ = rt_table_get_function(loc_675_, loc_721_, "i32,i32->");
										loc_721_(4, 1, loc_722_)
										loc_721_ = buffer_read_i32(loc_676_[1], 0, 10932);
									else
										loc_721_ = 0;
									end
									loc_714_ = (rt_equal_i32(loc_709_, 0) and 1 or 0);
									if not (rt_not_equal_i32(loc_714_, 0)) then
										loc_694_ = buffer_read_i32(loc_676_[1], loc_688_, 180);
										rt_memory_copy(loc_676_, bit32_or(bit32_or(loc_694_ + loc_717_, 0) + loc_723_, 0), loc_676_, loc_697_, loc_709_)
									end
									if not (rt_not_equal_i32(loc_714_, 0)) then
										loc_697_ = buffer_read_i32(loc_676_[1], loc_688_, 184);
										loc_714_ = buffer_read_i32(loc_676_[1], loc_688_, 160);
										rt_memory_copy(loc_676_, bit32_or(bit32_or(loc_697_ + loc_717_, 0) + loc_723_, 0), loc_676_, bit32_or(loc_714_ + loc_723_, 0), loc_709_)
									end
									loc_723_ = bit32_or(loc_723_ + loc_709_, 0);
									loc_693_ = loc_716_;
									loc_720_ = bit32_or(loc_720_ + loc_703_, 0);
									loc_719_ = bit32_or(loc_719_ + loc_716_, 0);
									loc_716_ = bit32_or(loc_718_ + -1, 0);
									loc_718_ = loc_716_;
								until loc_716_ == 0
								loc_721_ = buffer_read_i32(loc_676_[1], 0, 10932);
								loc_720_ = 0;
								loc_719_ = 0;
								loc_718_ = 0;
								loc_717_ = 0;
								loc_716_ = rt_shift_left_i32(loc_724_, 2);
								repeat
									rt_yield_budget = rt_yield_budget - 1
									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
									if rt_equal_i32(loc_721_, 0) then
										loc_714_ = loc_700_;
										loc_724_ = loc_721_;
									else
										loc_714_ = loc_700_;
										loc_724_ = loc_721_;
										loc_723_ = rt_table_get_function(loc_675_, loc_724_, "i32,i32->");
										loc_724_ = loc_722_;
										loc_723_(5, 0, loc_724_)
									end
									loc_724_ = buffer_read_i32(loc_676_[1], loc_688_, 136);
									loc_723_ = buffer_read_i32(loc_676_[1], loc_688_, 152);
									loc_690_ = buffer_read_i32(loc_676_[1], loc_688_, 180);
									loc_694_ = buffer_read_i32(loc_676_[1], loc_688_, 184);
									loc_697_ = buffer_read_i32(loc_676_[1], loc_688_, 108);
									loc_700_ = buffer_read_i32(loc_676_[1], loc_688_, 12);
									loc_721_ = buffer_read_i32(loc_676_[1], loc_688_, 24);
									loc_684_[1](bit32_or(loc_724_ + loc_720_, 0), bit32_or(loc_723_ + loc_720_, 0), bit32_or(loc_690_ + loc_716_, 0), bit32_or(loc_694_ + loc_716_, 0), loc_697_, loc_711_, bit32_or(loc_691_ + loc_718_, 0), loc_700_, loc_689_, loc_673_, loc_692_, loc_721_, loc_722_)
									loc_697_ = buffer_read_i32(loc_676_[1], 0, 10932);
									loc_700_ = 0;
									loc_721_ = 0;
									if not (rt_equal_i32(loc_697_, 0)) then
										loc_700_ = rt_table_get_function(loc_675_, loc_697_, "i32,i32->");
										loc_700_(5, 1, loc_722_)
										loc_700_ = buffer_read_i32(loc_676_[1], 0, 10932);
									end
									loc_697_ = buffer_read_i32(loc_676_[1], loc_688_, 164);
									rt_store_i32(loc_676_, loc_677_, 8, bit32_or(loc_697_ + loc_719_, 0))
									loc_697_ = buffer_read_i32(loc_676_[1], loc_688_, 168);
									rt_store_i32(loc_676_, loc_677_, 12, bit32_or(loc_697_ + loc_717_, 0))
									if not (rt_equal_i32(loc_700_, 0)) then
										loc_721_ = rt_table_get_function(loc_675_, loc_700_, "i32,i32->");
										loc_721_(2, 0, loc_722_)
										loc_721_ = buffer_read_i32(loc_676_[1], 0, 10932);
									end
									loc_700_ = buffer_read_i32(loc_676_[1], loc_688_, 136);
									loc_681_[1](bit32_or(loc_677_ + 8, 0), bit32_or(loc_700_ + loc_720_, 0), loc_696_, loc_695_, loc_722_)
									if rt_equal_i32(loc_721_, 0) then
										loc_721_ = 0;
										if rt_not_equal_i32(loc_702_, loc_718_) then
											loc_700_ = 0;
										else
											loc_700_ = loc_699_;
											loc_700_ = 1;
											loc_714_ = 0;
											loc_699_ = 1;
										end
									else
										loc_721_ = rt_table_get_function(loc_675_, loc_721_, "i32,i32->");
										loc_721_(2, 1, loc_722_)
										loc_721_ = buffer_read_i32(loc_676_[1], 0, 10932);
										if rt_equal_i32(loc_702_, loc_718_) then
											loc_700_ = loc_699_;
											loc_700_ = 1;
											loc_714_ = 0;
											loc_699_ = 0;
										else
											loc_700_ = 0;
										end
									end
									if not (rt_not_equal_i32(loc_700_, 0)) then
										loc_700_ = loc_704_;
										loc_704_ = loc_696_;
										loc_714_ = 1;
										loc_699_ = 65535;
										loc_720_ = bit32_or(loc_720_ + loc_693_, 0);
										loc_696_ = loc_704_;
										loc_719_ = bit32_or(loc_719_ + loc_704_, 0);
										loc_718_ = bit32_or(loc_718_ + 1, 0);
										loc_704_ = loc_700_;
										loc_717_ = bit32_or(loc_717_ + loc_700_, 0);
									end
									loc_700_ = loc_714_;
								until loc_714_ == 0
								if not (rt_not_equal_i32(loc_699_, 0)) then
									if not (rt_equal_i32(loc_721_, 0)) then
										loc_721_ = rt_table_get_function(loc_675_, loc_721_, "i32,i32->");
										loc_721_(3, 0, loc_722_)
									end
								end
								loc_720_ = buffer_read_i32(loc_676_[1], loc_688_, 140);
								loc_721_ = buffer_read_i32(loc_676_[1], loc_688_, 56);
								loc_687_[1](loc_720_, loc_706_, bit32_or(loc_721_ + loc_712_, 0), loc_696_, loc_696_, loc_695_, loc_713_, loc_722_)
								loc_722_ = buffer_read_i32(loc_676_[1], 0, 10932);
								if not (rt_equal_i32(loc_722_, 0)) then
									loc_721_ = rt_table_get_function(loc_675_, loc_722_, "i32,i32->");
									loc_722_ = loc_719_;
									loc_721_(3, 1, loc_722_)
								end
								loc_718_ = buffer_read_i32(loc_676_[1], 0, 10932);
								loc_717_ = 0;
								loc_697_ = loc_713_;
								loc_716_ = loc_718_;
								loc_714_ = 0;
								loc_694_ = 0;
								repeat
									rt_yield_budget = rt_yield_budget - 1
									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
									loc_722_ = 0;
									if rt_equal_i32(loc_716_, 0) then
										loc_690_ = loc_696_;
										loc_720_ = loc_704_;
										loc_721_ = loc_719_;
										loc_719_ = loc_716_;
									else
										loc_690_ = loc_696_;
										loc_720_ = loc_704_;
										loc_721_ = loc_722_;
										loc_722_ = loc_719_;
										loc_719_ = loc_716_;
										loc_721_ = rt_table_get_function(loc_675_, loc_719_, "i32,i32->");
										loc_721_(7, 0, loc_722_)
										loc_718_ = buffer_read_i32(loc_676_[1], 0, 10932);
										loc_722_ = loc_718_;
									end
									loc_716_ = buffer_read_i32(loc_676_[1], loc_688_, 132);
									loc_719_ = buffer_read_i32(loc_676_[1], loc_688_, 140);
									loc_685_[1](bit32_or(loc_716_ + loc_717_, 0), bit32_or(loc_719_ + loc_717_, 0), loc_690_, loc_721_)
									loc_696_ = 0;
									loc_716_ = 0;
									if not (rt_equal_i32(loc_722_, 0)) then
										loc_721_ = loc_716_;
										loc_721_ = rt_table_get_function(loc_675_, loc_722_, "i32,i32->");
										loc_722_ = loc_719_;
										loc_721_(7, 1, loc_722_)
										loc_722_ = buffer_read_i32(loc_676_[1], 0, 10932);
										loc_716_ = 0;
										loc_718_ = 0;
										if not (rt_equal_i32(loc_722_, 0)) then
											loc_721_ = loc_716_;
											loc_721_ = rt_table_get_function(loc_675_, loc_722_, "i32,i32->");
											loc_722_ = loc_719_;
											loc_721_(1, 0, loc_722_)
											loc_718_ = buffer_read_i32(loc_676_[1], 0, 10932);
											loc_716_ = loc_718_;
										end
									end
									loc_722_ = buffer_read_i32(loc_676_[1], loc_688_, 136);
									loc_721_ = buffer_read_i32(loc_676_[1], loc_688_, 132);
									loc_704_ = buffer_read_i32(loc_676_[1], loc_688_, 36);
									loc_680_[1](bit32_or(loc_722_ + loc_717_, 0), bit32_or(loc_721_ + loc_717_, 0), bit32_or(loc_704_ + loc_715_, 0), loc_690_, loc_719_)
									if not (rt_equal_i32(loc_716_, 0)) then
										loc_704_ = loc_718_;
										loc_718_ = loc_696_;
										loc_718_ = rt_table_get_function(loc_675_, loc_716_, "i32,i32->");
										loc_718_(1, 1, loc_719_)
										loc_718_ = buffer_read_i32(loc_676_[1], 0, 10932);
										loc_696_ = loc_718_;
									end
									loc_716_ = buffer_read_i32(loc_676_[1], loc_688_, 164);
									rt_store_i32(loc_676_, loc_677_, 8, bit32_or(loc_716_ + loc_714_, 0))
									loc_716_ = buffer_read_i32(loc_676_[1], loc_688_, 168);
									rt_store_i32(loc_676_, loc_677_, 12, bit32_or(loc_716_ + loc_694_, 0))
									loc_716_ = 0;
									loc_704_ = 0;
									if not (rt_equal_i32(loc_696_, 0)) then
										loc_704_, loc_718_ = loc_718_, loc_704_;
										loc_718_ = rt_table_get_function(loc_675_, loc_696_, "i32,i32->");
										loc_718_(2, 0, loc_719_)
										loc_718_ = buffer_read_i32(loc_676_[1], 0, 10932);
										loc_704_ = loc_718_;
									end
									loc_696_ = buffer_read_i32(loc_676_[1], loc_688_, 136);
									loc_681_[1](bit32_or(loc_677_ + 8, 0), bit32_or(loc_696_ + loc_717_, 0), loc_690_, loc_695_, loc_719_)
									if not (rt_equal_i32(loc_704_, 0)) then
										loc_716_, loc_718_ = loc_718_, loc_716_;
										loc_718_ = rt_table_get_function(loc_675_, loc_704_, "i32,i32->");
										loc_718_(2, 1, loc_719_)
										loc_718_ = buffer_read_i32(loc_676_[1], 0, 10932);
										loc_716_ = loc_718_;
									end
									loc_717_ = bit32_or(loc_717_ + loc_693_, 0);
									loc_696_ = loc_690_;
									loc_704_ = loc_720_;
									loc_714_ = bit32_or(loc_714_ + loc_690_, 0);
									loc_690_ = bit32_or(loc_713_ + -1, 0);
									loc_713_ = loc_690_;
									loc_694_ = bit32_or(loc_694_ + loc_720_, 0);
								until loc_690_ == 0
								if not (rt_equal_i32(loc_718_, 0)) then
									loc_718_ = rt_table_get_function(loc_675_, loc_718_, "i32,i32->");
									loc_718_(3, 0, loc_719_)
								end
								loc_717_ = buffer_read_i32(loc_676_[1], loc_688_, 144);
								loc_718_ = buffer_read_i32(loc_676_[1], loc_688_, 60);
								loc_687_[1](loc_717_, loc_706_, bit32_or(loc_718_ + loc_712_, 0), loc_696_, loc_698_, loc_695_, loc_697_, loc_719_)
								loc_717_ = buffer_read_i32(loc_676_[1], loc_688_, 148);
								loc_718_ = buffer_read_i32(loc_676_[1], loc_688_, 68);
								loc_687_[1](loc_717_, loc_706_, bit32_or(loc_718_ + loc_712_, 0), loc_696_, loc_698_, loc_695_, loc_697_, loc_719_)
								loc_719_ = buffer_read_i32(loc_676_[1], 0, 10932);
								if not (rt_equal_i32(loc_719_, 0)) then
									loc_718_ = rt_table_get_function(loc_675_, loc_719_, "i32,i32->");
									loc_719_ = loc_715_;
									loc_718_(3, 1, loc_719_)
								end
								loc_714_ = buffer_read_i32(loc_676_[1], 0, 10932);
								loc_713_ = 0;
								loc_694_ = 1;
								loc_690_ = 0;
								loc_716_ = 0;
								loc_717_ = 0;
								repeat
									rt_yield_budget = rt_yield_budget - 1
									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
									if rt_equal_i32(loc_714_, 0) then
										loc_718_ = loc_700_;
										loc_700_ = loc_699_;
										loc_719_ = loc_715_;
										loc_715_ = loc_714_;
									else
										loc_718_ = loc_700_;
										loc_700_ = loc_699_;
										loc_719_ = loc_715_;
										loc_715_ = loc_714_;
										loc_715_ = rt_table_get_function(loc_675_, loc_715_, "i32,i32->");
										loc_715_(6, 0, loc_719_)
									end
									loc_714_ = buffer_read_i32(loc_676_[1], loc_688_, 144);
									loc_715_ = buffer_read_i32(loc_676_[1], loc_688_, 148);
									loc_686_[1](bit32_or(loc_714_ + loc_713_, 0), bit32_or(loc_715_ + loc_713_, 0), loc_698_, loc_719_)
									loc_719_ = buffer_read_i32(loc_676_[1], 0, 10932);
									loc_714_ = 0;
									loc_699_ = 0;
									if not (rt_equal_i32(loc_719_, 0)) then
										loc_715_, loc_719_ = loc_719_, loc_715_;
										loc_715_ = rt_table_get_function(loc_675_, loc_715_, "i32,i32->");
										loc_715_(6, 1, loc_719_)
										loc_699_ = buffer_read_i32(loc_676_[1], 0, 10932);
									end
									loc_719_ = buffer_read_i32(loc_676_[1], loc_688_, 172);
									rt_store_i32(loc_676_, loc_677_, 8, bit32_or(loc_719_ + loc_690_, 0))
									loc_719_ = buffer_read_i32(loc_676_[1], loc_688_, 176);
									rt_store_i32(loc_676_, loc_677_, 12, bit32_or(loc_719_ + loc_716_, 0))
									if not (rt_equal_i32(loc_699_, 0)) then
										loc_714_ = rt_table_get_function(loc_675_, loc_699_, "i32,i32->");
										loc_714_(2, 0, loc_715_)
										loc_714_ = buffer_read_i32(loc_676_[1], 0, 10932);
									end
									loc_699_ = buffer_read_i32(loc_676_[1], loc_688_, 144);
									loc_681_[1](bit32_or(loc_677_ + 8, 0), bit32_or(loc_699_ + loc_713_, 0), loc_698_, loc_695_, loc_715_)
									if rt_equal_i32(loc_714_, 0) then
										if rt_equal_i32(loc_697_, loc_694_) then
											loc_700_ = 1;
											loc_718_ = 0;
											loc_699_ = 1;
										else
											loc_700_, loc_714_ = loc_714_, loc_700_;
											loc_700_ = 0;
											loc_699_ = loc_714_;
											loc_714_ = 0;
											loc_717_ = bit32_or(loc_717_ + 1, 0);
										end
									else
										loc_714_ = rt_table_get_function(loc_675_, loc_714_, "i32,i32->");
										loc_714_(2, 1, loc_715_)
										loc_714_ = buffer_read_i32(loc_676_[1], 0, 10932);
										if rt_equal_i32(loc_697_, loc_694_) then
											loc_700_ = 1;
											loc_718_ = 0;
											loc_699_ = 0;
										else
											loc_699_ = loc_700_;
											loc_700_ = 0;
											loc_717_ = bit32_or(loc_717_ + 1, 0);
										end
									end
									if not (rt_not_equal_i32(loc_700_, 0)) then
										loc_700_ = loc_701_;
										loc_701_ = loc_698_;
										loc_718_ = 1;
										loc_699_ = 65535;
										loc_713_ = bit32_or(loc_713_ + loc_672_, 0);
										loc_698_ = loc_701_;
										loc_694_ = bit32_or(loc_694_ + 1, 0);
										loc_690_ = bit32_or(loc_690_ + loc_701_, 0);
										loc_701_ = loc_700_;
										loc_716_ = bit32_or(loc_716_ + loc_700_, 0);
									end
									loc_700_ = loc_718_;
								until loc_718_ == 0
								if not (rt_not_equal_i32(loc_699_, 0)) then
									if not (rt_equal_i32(loc_714_, 0)) then
										loc_714_ = rt_table_get_function(loc_675_, loc_714_, "i32,i32->");
										loc_714_(3, 0, loc_715_)
									end
								end
								loc_713_ = buffer_read_i32(loc_676_[1], loc_688_, 136);
								loc_714_ = buffer_read_i32(loc_676_[1], loc_688_, 64);
								loc_687_[1](loc_713_, loc_705_, bit32_or(loc_714_ + loc_712_, 0), loc_698_, loc_696_, loc_695_, loc_697_, loc_715_)
								loc_715_ = buffer_read_i32(loc_676_[1], 0, 10932);
								if not (rt_equal_i32(loc_715_, 0)) then
									loc_714_ = rt_table_get_function(loc_675_, loc_715_, "i32,i32->");
									loc_715_ = loc_694_;
									loc_714_(3, 1, loc_715_)
								end
								loc_713_ = buffer_read_i32(loc_676_[1], 0, 10932);
								loc_712_ = 0;
								loc_690_ = loc_697_;
								repeat
									rt_yield_budget = rt_yield_budget - 1
									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
									loc_715_ = loc_697_;
									loc_697_ = 0;
									if rt_equal_i32(loc_713_, 0) then
										loc_714_ = loc_715_;
										loc_715_ = loc_713_;
										loc_713_ = loc_694_;
									else
										loc_714_ = loc_715_;
										loc_715_ = loc_694_;
										loc_713_ = rt_table_get_function(loc_675_, loc_713_, "i32,i32->");
										loc_713_(7, 0, loc_715_)
										loc_697_ = buffer_read_i32(loc_676_[1], 0, 10932);
									end
									loc_715_ = buffer_read_i32(loc_676_[1], loc_688_, 132);
									loc_694_ = buffer_read_i32(loc_676_[1], loc_688_, 136);
									loc_685_[1](bit32_or(loc_715_ + loc_712_, 0), bit32_or(loc_694_ + loc_712_, 0), loc_696_, loc_713_)
									if rt_not_equal_i32(loc_697_, 0) then
										loc_697_ = rt_table_get_function(loc_675_, loc_697_, "i32,i32->");
										loc_697_(7, 1, loc_713_)
										loc_713_ = buffer_read_i32(loc_676_[1], 0, 10932);
									else
										loc_697_, loc_713_ = loc_713_, loc_697_;
										loc_713_ = 0;
										loc_694_ = loc_697_;
									end
									loc_712_ = bit32_or(loc_712_ + loc_693_, 0);
									loc_714_ = bit32_or(loc_714_ + -1, 0);
									loc_697_ = loc_714_;
								until loc_714_ == 0
								loc_712_ = buffer_read_i32(loc_676_[1], loc_688_, 8);
								loc_697_ = loc_709_;
								loc_709_ = bit32_or(loc_710_ + loc_709_, 0);
								loc_711_ = bit32_or(loc_711_ + 1, 0);
								loc_710_ = loc_711_;
							until not (rt_less_than_s32(loc_711_, loc_712_))
						end
						loc_689_ = buffer_read_i32(loc_676_[1], loc_688_, 76);
						loc_693_ = rt_shift_left_i32(loc_696_, 2);
						if not (rt_equal_i32(loc_693_, 0)) then
							loc_692_ = buffer_read_i32(loc_676_[1], loc_688_, 132);
							rt_memory_copy(loc_676_, loc_689_, loc_676_, bit32_or(loc_692_ + rt_shift_left_i32(rt_multiply_i32(loc_696_, bit32_or(loc_690_ + -1, 0)), 2), 0), loc_693_)
						end
						loc_693_ = buffer_read_i32(loc_676_[1], 0, 10932);
						if rt_not_equal_i32(loc_693_, 0) then
							loc_693_ = rt_table_get_function(loc_675_, loc_693_, "i32,i32->");
							loc_693_(1, 0, loc_694_)
							loc_693_ = buffer_read_i32(loc_676_[1], 0, 10932);
							loc_692_ = buffer_read_i32(loc_676_[1], loc_688_, 40);
							loc_680_[1](loc_689_, loc_689_, loc_692_, loc_696_, loc_694_)
							if rt_not_equal_i32(loc_693_, 0) then
								loc_693_ = rt_table_get_function(loc_675_, loc_693_, "i32,i32->");
								loc_693_(1, 1, loc_694_)
								loc_692_ = buffer_read_i32(loc_676_[1], 0, 10932);
								if rt_not_equal_i32(loc_692_, 0) then
									loc_694_ = bit32_or(loc_688_ + 116, 0);
									loc_692_ = rt_table_get_function(loc_675_, loc_692_, "i32,i32->");
									loc_692_(2, 0, loc_693_)
									loc_692_ = buffer_read_i32(loc_676_[1], 0, 10932);
									loc_681_[1](loc_694_, loc_689_, loc_696_, loc_695_, loc_693_)
									if rt_equal_i32(loc_692_, 0) then
										loc_692_ = 1;
									else
										loc_692_ = rt_table_get_function(loc_675_, loc_692_, "i32,i32->");
										loc_692_(2, 1, loc_693_)
										loc_689_ = buffer_read_i32(loc_676_[1], 0, 10932);
										if rt_equal_i32(loc_689_, 0) then
											loc_692_ = 1;
										else
											loc_692_ = rt_table_get_function(loc_675_, loc_689_, "i32,i32->");
											loc_692_(8, 0, loc_693_)
											loc_692_ = 1;
										end
									end
								else
									loc_694_ = loc_692_;
									loc_692_ = 0;
								end
							else
								loc_692_ = loc_681_;
								loc_693_, loc_694_ = loc_694_, loc_693_;
								loc_681_ = loc_692_;
								loc_694_ = bit32_or(loc_688_ + 116, 0);
								loc_692_[1](loc_694_, loc_689_, loc_696_, loc_695_, loc_693_)
								loc_692_ = 1;
							end
						else
							loc_673_ = loc_680_;
							loc_693_, loc_694_ = loc_694_, loc_693_;
							loc_680_ = loc_673_;
							loc_692_ = buffer_read_i32(loc_676_[1], loc_688_, 40);
							loc_673_[1](loc_689_, loc_689_, loc_692_, loc_696_, loc_693_)
							loc_692_ = 0;
						end
						if not (rt_not_equal_i32(loc_692_, 0)) then
							loc_692_ = loc_681_;
							loc_681_ = loc_692_;
							loc_694_ = bit32_or(loc_688_ + 116, 0);
							loc_692_[1](loc_694_, loc_689_, loc_696_, loc_695_, loc_693_)
						end
						loc_672_ = buffer_read_i32(loc_676_[1], loc_688_, 112);
						loc_673_ = buffer_read_i32(loc_676_[1], loc_688_, 72);
						loc_692_ = buffer_read_i32(loc_676_[1], loc_688_, 20);
						loc_682_[1](loc_672_, loc_694_, loc_673_, loc_696_, loc_692_, loc_695_, loc_693_)
						loc_693_ = buffer_read_i32(loc_676_[1], 0, 10932);
						if not (rt_equal_i32(loc_693_, 0)) then
							loc_692_ = rt_table_get_function(loc_675_, loc_693_, "i32,i32->");
							loc_693_ = loc_672_;
							loc_692_(8, 1, loc_693_)
						end
						loc_673_ = buffer_read_i32(loc_676_[1], loc_688_, 112);
						loc_692_ = 1;
					else
						loc_694_ = loc_672_;
						loc_720_ = loc_693_;
						loc_721_ = loc_692_;
						loc_722_ = loc_690_;
						loc_723_ = loc_673_;
						loc_724_ = loc_689_;
						loc_692_ = 0;
						loc_689_ = loc_724_;
						loc_690_ = loc_722_;
						loc_673_ = loc_723_;
						loc_672_ = loc_694_;
					end
				end
				if not (rt_not_equal_i32(loc_692_, 0)) then
					loc_692_ = loc_691_;
					loc_689_, loc_690_ = loc_690_, loc_689_;
					loc_691_ = loc_688_;
					loc_688_ = loc_692_;
					repeat
						rt_yield_budget = rt_yield_budget - 1
						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
						loc_692_ = loc_672_;
						loc_672_ = loc_678_;
						loc_678_ = loc_673_;
						loc_678_ = loc_672_;
						loc_673_ = buffer_read_i32(loc_676_[1], loc_690_, 0);
						loc_673_ = loc_672_[1](loc_691_, loc_673_, loc_688_, loc_692_)
						loc_690_ = bit32_or(loc_690_ + 4, 0);
						loc_692_ = bit32_or(loc_689_ + -1, 0);
						loc_689_ = loc_692_;
						loc_688_ = bit32_or(loc_688_ + 1, 0);
					until loc_692_ == 0
				end
			else
				loc_672_ = loc_671_;
				loc_675_ = loc_665_;
				loc_676_ = loc_666_;
				loc_678_ = loc_654_;
				loc_679_ = loc_655_;
				loc_680_ = loc_656_;
				loc_681_ = loc_657_;
				loc_682_ = loc_658_;
				loc_683_ = loc_659_;
				loc_684_ = loc_660_;
				loc_685_ = loc_661_;
				loc_686_ = loc_662_;
				loc_687_ = loc_663_;
				loc_718_ = loc_673_;
				loc_719_ = loc_670_;
				loc_720_ = loc_669_;
				loc_721_ = loc_668_;
				loc_722_ = loc_667_;
				loc_723_ = loc_693_;
				loc_724_ = loc_692_;
				loc_673_ = 0;
			end
			loc_674_[1] = bit32_or(loc_677_ + 16, 0);
			return loc_673_, loc_672_
		end), "i32,i32,i32,i32->i32")
	end)(module_locals[49], module_locals[50], module_locals[51], module_locals[52], module_locals[53], module_locals[54], module_locals[55], module_locals[56], module_locals[57], module_locals[61], module_locals[164], module_locals[162], module_locals[3]);
	do (function() --[[spider:chunk]]
	module_locals[61][1] = (function(loc_725_, loc_726_, loc_727_, loc_728_)
		return rt_function_type(--[[fn:k_matmul_q8]](function(loc_729_, loc_730_, loc_731_, loc_732_, loc_733_, loc_734_, loc_735_, loc_736_)
			local loc_737_, loc_738_, loc_739_, loc_740_, loc_741_, loc_742_, loc_743_, loc_744_, loc_745_, loc_746_, loc_747_, loc_748_, loc_749_, loc_750_, loc_751_, loc_752_, loc_753_, loc_754_, loc_755_
			loc_755_ = loc_726_[1];
			loc_738_ = loc_726_;
			loc_741_ = bit32_or(loc_755_ - 16, 0);
			loc_738_[1] = loc_741_;
			loc_755_ = buffer_read_i32(loc_728_[1], 0, 10936);
			loc_740_ = loc_728_;
			loc_750_ = 0;
			if rt_equal_i32(loc_755_, 0) then
				loc_737_ = loc_736_;
				loc_739_ = loc_727_;
				loc_742_ = loc_725_;
				loc_743_ = loc_729_;
				loc_744_ = loc_730_;
				loc_745_ = loc_731_;
				loc_746_ = loc_732_;
				loc_747_ = loc_733_;
				loc_748_ = loc_734_;
				loc_749_ = loc_735_;
				loc_755_ = 0;
			else
				loc_739_ = loc_727_;
				loc_742_ = loc_725_;
				loc_743_ = loc_729_;
				loc_744_ = loc_730_;
				loc_745_ = loc_731_;
				loc_746_ = loc_732_;
				loc_747_ = loc_733_;
				loc_748_ = loc_734_;
				loc_749_ = loc_735_;
				loc_754_ = loc_755_;
				loc_755_ = loc_736_;
				loc_737_ = rt_table_get_function(loc_739_, loc_754_, "i32,i32,i32,i32,i32,i32,i32,i32,i32->i32");
				loc_751_ = buffer_read_i32(loc_740_[1], loc_744_, 0);
				loc_752_ = buffer_read_i32(loc_740_[1], loc_744_, 4);
				loc_753_ = buffer_read_i32(loc_740_[1], loc_745_, 0);
				loc_754_ = buffer_read_i32(loc_740_[1], loc_745_, 4);
				loc_755_ = loc_737_(loc_743_, loc_751_, loc_752_, loc_753_, loc_754_, loc_746_, loc_747_, loc_748_, loc_749_, loc_755_)
				if rt_not_equal_i32(loc_755_, 0) then
					loc_755_ = 1;
				else
					loc_755_ = 0;
				end
			end
			if not (rt_not_equal_i32(loc_755_, 0)) then
				loc_751_ = loc_749_;
				loc_752_ = loc_750_;
				loc_753_ = loc_747_;
				loc_754_ = loc_746_;
				loc_755_ = loc_748_;
				loc_750_ = loc_743_;
				loc_749_ = loc_744_;
				loc_748_ = loc_745_;
				loc_747_ = loc_754_;
				loc_746_ = loc_753_;
				loc_745_ = loc_755_;
				loc_744_ = loc_751_;
				loc_743_ = loc_752_;
				loc_751_ = 0;
				loc_752_ = rt_shift_left_i32(loc_753_, 2);
				loc_755_ = rt_divide_s32(loc_754_, loc_755_);
				loc_753_ = rt_shift_left_i32(loc_755_, 2);
				repeat
					rt_yield_budget = rt_yield_budget - 1
					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
					loc_755_ = loc_747_;
					loc_747_ = loc_742_;
					loc_742_ = loc_747_;
					loc_754_ = buffer_read_i32(loc_740_[1], loc_749_, 0);
					rt_store_i32(loc_740_, loc_741_, 8, bit32_or(loc_754_ + loc_743_, 0))
					loc_754_ = buffer_read_i32(loc_740_[1], loc_749_, 4);
					rt_store_i32(loc_740_, loc_741_, 12, bit32_or(loc_754_ + loc_751_, 0))
					loc_754_ = loc_737_;
					loc_747_[1](loc_750_, bit32_or(loc_741_ + 8, 0), loc_748_, loc_755_, loc_746_, loc_745_, loc_754_)
					loc_750_ = bit32_or(loc_750_ + loc_752_, 0);
					loc_747_ = loc_755_;
					loc_754_ = bit32_or(loc_744_ + -1, 0);
					loc_744_ = loc_754_;
					loc_743_ = bit32_or(loc_743_ + loc_755_, 0);
					loc_751_ = bit32_or(loc_751_ + loc_753_, 0);
				until loc_754_ == 0
			end
			loc_738_[1] = bit32_or(loc_741_ + 16, 0);
			return loc_737_
		end), "i32,i32,i32,i32,i32,i32,i32->")
	end)(module_locals[58], module_locals[164], module_locals[162], module_locals[3]);
	module_locals[62] = { nil };
	module_locals[63] = { nil };
	end)() end --[[/spider:chunk]]
	module_locals[62][1] = (function(loc_756_, loc_757_, loc_758_, loc_759_, loc_760_, loc_761_, loc_762_, loc_763_, loc_764_, loc_765_, loc_766_, loc_767_, loc_768_, loc_769_)
		return rt_function_type(--[[fn:model_kernels_selftest]](function(loc_770_, loc_771_, loc_772_, loc_773_)
			local loc_774_, loc_775_, loc_776_, loc_777_, loc_778_, loc_779_, loc_780_, loc_781_, loc_782_, loc_783_, loc_784_, loc_785_, loc_786_, loc_787_, loc_788_, loc_789_, loc_790_, loc_791_, loc_792_, loc_793_, loc_794_, loc_795_, loc_796_, loc_797_, loc_798_, loc_799_, loc_800_, loc_801_, loc_802_, loc_803_, loc_804_, loc_805_, loc_806_, loc_807_, loc_808_, loc_809_, loc_810_, loc_811_, loc_812_, loc_813_, loc_814_, loc_815_, loc_816_, loc_817_, loc_818_, loc_819_, loc_820_
			loc_820_ = loc_767_[1];
			loc_776_ = loc_767_;
			loc_779_ = bit32_or(loc_820_ - 32, 0);
			loc_794_ = buffer_read_i32(loc_769_[1], loc_770_, 0);
			loc_778_ = loc_769_;
			loc_818_ = buffer_read_i32(loc_778_[1], loc_770_, 12);
			loc_795_ = rt_divide_s32(loc_794_, loc_818_);
			loc_819_ = loc_795_;
			loc_820_ = loc_773_;
			loc_819_ = buffer_read_i32(loc_778_[1], loc_770_, 16);
			loc_796_ = rt_divide_s32(loc_818_, loc_819_);
			loc_817_ = loc_796_;
			loc_797_ = rt_divide_s32(rt_multiply_i32(loc_819_, loc_794_), loc_818_);
			loc_819_ = loc_797_;
			loc_776_[1] = loc_779_;
			loc_798_ = buffer_read_i32(loc_778_[1], loc_770_, 4);
			loc_799_ = buffer_read_i32(loc_778_[1], loc_770_, 204);
			loc_777_ = loc_768_;
			loc_775_ = loc_764_[1](loc_771_, 1288, bit32_or(loc_779_ + 24, 0), loc_820_)
			loc_800_ = 0;
			if rt_equal_i32(loc_775_, 0) then
				loc_780_ = loc_756_;
				loc_781_ = loc_757_;
				loc_782_ = loc_758_;
				loc_783_ = loc_759_;
				loc_784_ = loc_760_;
				loc_785_ = loc_761_;
				loc_786_ = loc_762_;
				loc_787_ = loc_763_;
				loc_788_ = loc_764_;
				loc_789_ = loc_765_;
				loc_790_ = loc_766_;
				loc_791_ = loc_770_;
				loc_792_ = loc_771_;
				loc_793_ = loc_772_;
				loc_791_ = 0;
			else
				loc_780_ = loc_756_;
				loc_781_ = loc_757_;
				loc_782_ = loc_758_;
				loc_783_ = loc_759_;
				loc_784_ = loc_760_;
				loc_785_ = loc_761_;
				loc_786_ = loc_762_;
				loc_787_ = loc_763_;
				loc_788_ = loc_764_;
				loc_789_ = loc_765_;
				loc_790_ = loc_766_;
				loc_791_ = loc_770_;
				loc_792_ = loc_771_;
				loc_793_ = loc_772_;
				loc_820_ = buffer_read_i32(loc_778_[1], loc_779_, 24);
				if rt_equal_i32(loc_820_, 16) then
					loc_801_ = loc_799_;
					loc_802_ = loc_794_;
					loc_803_ = loc_796_;
					loc_805_ = loc_798_;
					loc_798_ = loc_793_;
					loc_807_ = loc_795_;
					loc_812_ = loc_800_;
					loc_800_ = loc_797_;
					loc_816_ = loc_790_;
					loc_819_ = loc_775_;
					loc_820_ = loc_774_;
					loc_791_, loc_792_ = loc_792_, loc_791_;
					loc_799_ = buffer_read_i32(loc_778_[1], loc_819_, 4);
					loc_790_ = buffer_read_i32(loc_778_[1], loc_819_, 0);
					loc_818_ = buffer_read_i32(loc_778_[1], loc_819_, 8);
					loc_816_[1](loc_819_, loc_820_)
					loc_819_ = buffer_read_i32(loc_778_[1], loc_792_, 20);
					loc_793_ = loc_789_[1](rt_shift_left_i32(loc_819_, 2), loc_820_)
					loc_819_ = rt_divide_s32(loc_805_, loc_801_);
					loc_804_ = rt_shift_left_i32(loc_805_, 2);
					loc_794_ = loc_789_[1](loc_804_, loc_820_)
					loc_795_ = loc_789_[1](loc_805_, loc_820_)
					loc_817_ = loc_819_;
					rt_store_i32(loc_778_, loc_779_, 16, loc_795_)
					loc_797_ = loc_789_[1](rt_shift_left_i32(loc_819_, 2), loc_820_)
					rt_store_i32(loc_778_, loc_779_, 20, loc_797_)
					loc_819_ = buffer_read_i32(loc_778_[1], loc_792_, 28);
					loc_780_[1](loc_793_, loc_819_, loc_818_, loc_802_, loc_801_, loc_820_)
					rt_store_i32(loc_778_, loc_779_, 8, 0)
					loc_818_ = loc_788_[1](loc_791_, 1411, bit32_or(loc_779_ + 8, 0), loc_820_)
					loc_775_ = rt_shift_left_i32(loc_802_, 2);
					if rt_not_equal_i32(loc_818_, 0) then
						loc_820_ = buffer_read_i32(loc_778_[1], loc_779_, 8);
						if rt_equal_i32(loc_820_, loc_775_) then
							loc_817_ = -1;
							if rt_greater_than_equal_s32(loc_802_, 1) then
								loc_815_ = 0;
								loc_820_ = 0;
								repeat
									rt_yield_budget = rt_yield_budget - 1
									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
									loc_814_ = bit32_or(loc_815_ + 1, 0);
									if rt_less_than_s32(loc_817_, 0) then
										loc_808_ = loc_815_;
										loc_810_ = loc_820_;
										loc_813_ = loc_775_;
										loc_820_ = loc_817_;
										loc_814_, loc_817_ = loc_817_, loc_814_;
									else
										loc_810_ = loc_820_;
										loc_811_ = loc_815_;
										loc_813_ = loc_775_;
										loc_820_ = loc_817_;
										loc_814_, loc_817_ = loc_817_, loc_814_;
										loc_808_ = loc_820_;
									end
									loc_809_ = bit32_or(loc_793_ + loc_815_, 0);
									loc_806_ = rt_load_i32_from_u8(loc_778_, loc_809_, 0);
									loc_811_ = bit32_or(loc_818_ + loc_815_, 0);
									loc_820_ = rt_load_i32_from_u8(loc_778_, loc_811_, 0);
									loc_820_ = (rt_not_equal_i32(rt_and_i32(loc_806_, 255), rt_and_i32(loc_820_, 255)) and 1 or 0);
									if not (rt_not_equal_i32(loc_820_, 0)) then
										loc_808_ = loc_814_;
									end
									if rt_less_than_s32(loc_808_, 0) then
										loc_814_ = loc_808_;
									else
										loc_814_ = loc_808_;
										loc_817_ = loc_808_;
									end
									loc_809_ = rt_load_i32_from_u8(loc_778_, bit32_or(loc_809_ + 1, 0), 0);
									loc_811_ = rt_load_i32_from_u8(loc_778_, bit32_or(loc_811_ + 1, 0), 0);
									loc_811_ = (rt_not_equal_i32(loc_809_, loc_811_) and 1 or 0);
									if not (rt_not_equal_i32(loc_811_, 0)) then
										loc_817_ = loc_814_;
									end
									loc_814_ = bit32_or(loc_815_ + 2, 0);
									loc_815_ = loc_814_;
									loc_775_ = loc_813_;
									loc_820_ = bit32_or(bit32_or(loc_810_ + loc_820_, 0) + loc_811_, 0);
								until not (rt_not_equal_i32(loc_814_, loc_813_))
							else
								loc_820_ = 0;
							end
						else
							loc_817_ = loc_820_;
							loc_820_ = -2;
						end
						loc_796_ = loc_816_;
						loc_816_[1](loc_818_, loc_819_)
						loc_818_ = rt_table_get_function(loc_777_, loc_798_, "i32,i32,i32,i32->");
						loc_818_(1220, (rt_equal_i32(loc_820_, 0) and 1 or 0), loc_820_, loc_817_, loc_819_)
						loc_820_ = (rt_not_equal_i32(loc_820_, 0) and 1 or 0);
					else
						loc_820_ = loc_819_;
						loc_819_ = loc_818_;
						loc_796_ = loc_816_;
						loc_819_ = rt_table_get_function(loc_777_, loc_798_, "i32,i32,i32,i32->");
						loc_819_(1220, 0, -1, -1, loc_820_)
						loc_820_ = 1;
					end
					loc_818_ = loc_788_[1](loc_791_, 1549, bit32_or(loc_779_ + 24, 0), loc_819_)
					if rt_equal_i32(loc_818_, 0) then
						loc_818_ = rt_table_get_function(loc_777_, loc_798_, "i32,i32,i32,i32->");
						loc_818_(1185, 0, -1, -1, loc_819_)
						loc_806_ = 1;
					else
						loc_817_ = buffer_read_i32(loc_778_[1], loc_792_, 32);
						loc_781_[1](loc_793_, loc_818_, bit32_or(loc_817_ + rt_shift_left_i32(rt_multiply_i32(loc_799_, loc_802_), 2), 0), loc_802_, loc_819_)
						rt_store_i32(loc_778_, loc_779_, 8, 0)
						loc_815_ = loc_788_[1](loc_791_, 1380, bit32_or(loc_779_ + 8, 0), loc_819_)
						if rt_not_equal_i32(loc_815_, 0) then
							loc_816_ = loc_796_;
							loc_817_ = loc_818_;
							loc_818_ = buffer_read_i32(loc_778_[1], loc_779_, 8);
							if rt_equal_i32(loc_818_, loc_775_) then
								loc_814_ = -1;
								if rt_greater_than_equal_s32(loc_802_, 1) then
									loc_813_ = 0;
									loc_818_ = 0;
									repeat
										rt_yield_budget = rt_yield_budget - 1
										if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
										loc_811_ = bit32_or(loc_813_ + 1, 0);
										if rt_less_than_s32(loc_814_, 0) then
											loc_796_ = loc_813_;
											loc_808_ = loc_818_;
											loc_810_ = loc_775_;
											loc_818_ = loc_814_;
											loc_811_, loc_814_ = loc_814_, loc_811_;
										else
											loc_808_ = loc_818_;
											loc_809_ = loc_813_;
											loc_810_ = loc_775_;
											loc_818_ = loc_814_;
											loc_811_, loc_814_ = loc_814_, loc_811_;
											loc_796_ = loc_818_;
										end
										loc_806_ = bit32_or(loc_793_ + loc_813_, 0);
										loc_775_ = rt_load_i32_from_u8(loc_778_, loc_806_, 0);
										loc_809_ = bit32_or(loc_815_ + loc_813_, 0);
										loc_818_ = rt_load_i32_from_u8(loc_778_, loc_809_, 0);
										loc_818_ = (rt_not_equal_i32(rt_and_i32(loc_775_, 255), rt_and_i32(loc_818_, 255)) and 1 or 0);
										if not (rt_not_equal_i32(loc_818_, 0)) then
											loc_796_ = loc_811_;
										end
										if rt_less_than_s32(loc_796_, 0) then
											loc_811_ = loc_796_;
										else
											loc_811_ = loc_796_;
											loc_814_ = loc_796_;
										end
										loc_806_ = rt_load_i32_from_u8(loc_778_, bit32_or(loc_806_ + 1, 0), 0);
										loc_809_ = rt_load_i32_from_u8(loc_778_, bit32_or(loc_809_ + 1, 0), 0);
										loc_809_ = (rt_not_equal_i32(loc_806_, loc_809_) and 1 or 0);
										if not (rt_not_equal_i32(loc_809_, 0)) then
											loc_814_ = loc_811_;
										end
										loc_811_ = bit32_or(loc_813_ + 2, 0);
										loc_813_ = loc_811_;
										loc_775_ = loc_810_;
										loc_818_ = bit32_or(bit32_or(loc_808_ + loc_818_, 0) + loc_809_, 0);
									until not (rt_not_equal_i32(loc_811_, loc_810_))
								else
									loc_818_ = 0;
								end
							else
								loc_814_ = loc_818_;
								loc_818_ = -2;
							end
							loc_796_ = loc_816_;
							loc_816_[1](loc_815_, loc_819_)
							loc_815_ = rt_table_get_function(loc_777_, loc_798_, "i32,i32,i32,i32->");
							loc_815_(1185, (rt_equal_i32(loc_818_, 0) and 1 or 0), loc_818_, loc_814_, loc_819_)
							loc_816_[1](loc_817_, loc_819_)
							loc_806_ = (rt_not_equal_i32(loc_818_, 0) and 1 or 0);
						else
							loc_816_ = loc_796_;
							loc_817_ = loc_818_;
							loc_818_ = loc_815_;
							loc_796_ = loc_816_;
							loc_818_ = rt_table_get_function(loc_777_, loc_798_, "i32,i32,i32,i32->");
							loc_818_(1185, 0, -1, -1, loc_819_)
							loc_816_[1](loc_817_, loc_819_)
							loc_806_ = 1;
						end
					end
					loc_818_ = loc_788_[1](loc_791_, 1578, bit32_or(loc_779_ + 24, 0), loc_819_)
					loc_820_ = bit32_or(loc_806_ + loc_820_, 0);
					if rt_equal_i32(loc_818_, 0) then
						loc_818_ = rt_table_get_function(loc_777_, loc_798_, "i32,i32,i32,i32->");
						loc_818_(1206, 0, -1, -1, loc_819_)
						loc_820_ = bit32_or(loc_820_ + 1, 0);
					else
						loc_817_ = loc_806_;
						loc_782_[1](bit32_or(loc_779_ + 16, 0), loc_818_, loc_802_, loc_801_, loc_819_)
						rt_store_i32(loc_778_, loc_779_, 8, 0)
						loc_816_ = loc_788_[1](loc_791_, 1262, bit32_or(loc_779_ + 8, 0), loc_819_)
						if rt_not_equal_i32(loc_816_, 0) then
							loc_811_ = loc_802_;
							loc_814_ = loc_796_;
							loc_817_ = loc_818_;
							loc_818_ = loc_812_;
							loc_815_ = buffer_read_i32(loc_778_[1], loc_779_, 8);
							if rt_equal_i32(loc_815_, loc_811_) then
								if rt_greater_than_equal_s32(loc_811_, 1) then
									loc_812_ = rt_and_i32(loc_811_, 1);
									if rt_not_equal_i32(loc_811_, 1) then
										loc_802_ = loc_811_;
										loc_813_ = 0;
										loc_815_ = -1;
										loc_818_ = 0;
										loc_811_ = rt_and_i32(loc_811_, 2147483646);
										repeat
											rt_yield_budget = rt_yield_budget - 1
											if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
											loc_810_ = bit32_or(loc_813_ + 1, 0);
											if rt_less_than_s32(loc_815_, 0) then
												loc_796_ = loc_813_;
												loc_808_ = loc_818_;
												loc_809_ = loc_811_;
												loc_818_ = loc_815_;
												loc_810_, loc_815_ = loc_815_, loc_810_;
											else
												loc_808_ = loc_818_;
												loc_809_ = loc_811_;
												loc_811_ = loc_813_;
												loc_818_ = loc_815_;
												loc_810_, loc_815_ = loc_815_, loc_810_;
												loc_796_ = loc_818_;
											end
											loc_806_ = bit32_or(loc_795_ + loc_813_, 0);
											loc_774_ = rt_load_i32_from_u8(loc_778_, loc_806_, 0);
											loc_811_ = bit32_or(loc_816_ + loc_813_, 0);
											loc_818_ = rt_load_i32_from_u8(loc_778_, loc_811_, 0);
											loc_818_ = (rt_not_equal_i32(rt_and_i32(loc_774_, 255), rt_and_i32(loc_818_, 255)) and 1 or 0);
											if not (rt_not_equal_i32(loc_818_, 0)) then
												loc_796_ = loc_810_;
											end
											if rt_less_than_s32(loc_796_, 0) then
												loc_810_ = loc_796_;
											else
												loc_810_ = loc_796_;
												loc_815_ = loc_796_;
											end
											loc_806_ = rt_load_i32_from_u8(loc_778_, bit32_or(loc_806_ + 1, 0), 0);
											loc_811_ = rt_load_i32_from_u8(loc_778_, bit32_or(loc_811_ + 1, 0), 0);
											loc_811_ = (rt_not_equal_i32(loc_806_, loc_811_) and 1 or 0);
											if not (rt_not_equal_i32(loc_811_, 0)) then
												loc_815_ = loc_810_;
											end
											loc_810_ = bit32_or(loc_813_ + 2, 0);
											loc_813_ = loc_810_;
											loc_818_ = bit32_or(bit32_or(loc_808_ + loc_818_, 0) + loc_811_, 0);
											loc_811_ = loc_809_;
										until not (rt_not_equal_i32(loc_810_, loc_809_))
									else
										loc_802_ = loc_811_;
										loc_813_ = 0;
										loc_815_ = -1;
										loc_818_ = 0;
									end
									if not (rt_equal_i32(loc_812_, 0)) then
										if rt_less_than_s32(loc_815_, 0) then
											loc_810_ = loc_815_;
											loc_811_ = loc_815_;
											loc_815_ = loc_813_;
										else
											loc_810_ = loc_815_;
											loc_811_ = loc_815_;
											loc_815_ = loc_813_;
											loc_815_ = loc_810_;
										end
										loc_810_ = rt_load_i32_from_u8(loc_778_, bit32_or(loc_795_ + loc_813_, 0), 0);
										loc_813_ = rt_load_i32_from_u8(loc_778_, bit32_or(loc_816_ + loc_813_, 0), 0);
										loc_813_ = (rt_not_equal_i32(loc_810_, loc_813_) and 1 or 0);
										if not (rt_not_equal_i32(loc_813_, 0)) then
											loc_815_ = loc_811_;
										end
										loc_818_ = bit32_or(loc_818_ + loc_813_, 0);
									end
								else
									loc_813_ = loc_818_;
									loc_802_ = loc_811_;
									loc_815_ = -1;
									loc_818_ = 0;
									loc_812_ = loc_813_;
								end
							else
								loc_813_ = loc_818_;
								loc_802_ = loc_811_;
								loc_818_ = -2;
								loc_812_ = loc_813_;
							end
							loc_813_ = loc_814_;
							loc_814_[1](loc_816_, loc_819_)
							loc_816_ = rt_table_get_function(loc_777_, loc_798_, "i32,i32,i32,i32->");
							loc_816_(1659, (rt_equal_i32(loc_818_, 0) and 1 or 0), loc_818_, loc_815_, loc_819_)
							loc_816_ = (rt_not_equal_i32(loc_818_, 0) and 1 or 0);
						else
							loc_811_ = loc_802_;
							loc_814_ = loc_796_;
							loc_817_ = loc_818_;
							loc_818_ = loc_812_;
							loc_813_ = loc_814_;
							loc_816_ = rt_table_get_function(loc_777_, loc_798_, "i32,i32,i32,i32->");
							loc_816_(1659, 0, -1, -1, loc_819_)
							loc_802_ = loc_811_;
							loc_816_ = 1;
							loc_812_ = loc_818_;
						end
						loc_818_ = rt_divide_s32(loc_802_, loc_801_);
						loc_815_ = loc_818_;
						rt_store_i32(loc_778_, loc_779_, 8, 0)
						loc_815_ = loc_788_[1](loc_791_, 1481, bit32_or(loc_779_ + 8, 0), loc_819_)
						loc_820_ = bit32_or(loc_816_ + loc_820_, 0);
						if rt_not_equal_i32(loc_815_, 0) then
							loc_816_ = buffer_read_i32(loc_778_[1], loc_779_, 8);
							loc_811_ = rt_shift_left_i32(loc_818_, 2);
							if rt_equal_i32(loc_816_, loc_811_) then
								loc_814_ = -1;
								if rt_greater_than_equal_s32(loc_818_, 1) then
									loc_816_ = 0;
									loc_818_ = 0;
									repeat
										rt_yield_budget = rt_yield_budget - 1
										if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
										loc_810_ = bit32_or(loc_816_ + 1, 0);
										if rt_less_than_s32(loc_814_, 0) then
											loc_796_ = loc_816_;
											loc_808_ = loc_818_;
											loc_809_ = loc_811_;
											loc_818_ = loc_814_;
											loc_810_, loc_814_ = loc_814_, loc_810_;
										else
											loc_808_ = loc_818_;
											loc_809_ = loc_811_;
											loc_811_ = loc_816_;
											loc_818_ = loc_814_;
											loc_810_, loc_814_ = loc_814_, loc_810_;
											loc_796_ = loc_818_;
										end
										loc_806_ = bit32_or(loc_797_ + loc_816_, 0);
										loc_774_ = rt_load_i32_from_u8(loc_778_, loc_806_, 0);
										loc_811_ = bit32_or(loc_815_ + loc_816_, 0);
										loc_818_ = rt_load_i32_from_u8(loc_778_, loc_811_, 0);
										loc_818_ = (rt_not_equal_i32(rt_and_i32(loc_774_, 255), rt_and_i32(loc_818_, 255)) and 1 or 0);
										if not (rt_not_equal_i32(loc_818_, 0)) then
											loc_796_ = loc_810_;
										end
										if rt_less_than_s32(loc_796_, 0) then
											loc_810_ = loc_796_;
										else
											loc_810_ = loc_796_;
											loc_814_ = loc_796_;
										end
										loc_806_ = rt_load_i32_from_u8(loc_778_, bit32_or(loc_806_ + 1, 0), 0);
										loc_811_ = rt_load_i32_from_u8(loc_778_, bit32_or(loc_811_ + 1, 0), 0);
										loc_811_ = (rt_not_equal_i32(loc_806_, loc_811_) and 1 or 0);
										if not (rt_not_equal_i32(loc_811_, 0)) then
											loc_814_ = loc_810_;
										end
										loc_810_ = bit32_or(loc_816_ + 2, 0);
										loc_816_ = loc_810_;
										loc_818_ = bit32_or(bit32_or(loc_808_ + loc_818_, 0) + loc_811_, 0);
										loc_811_ = loc_809_;
									until not (rt_not_equal_i32(loc_810_, loc_809_))
								else
									loc_818_ = loc_811_;
									loc_818_ = 0;
								end
							else
								loc_814_ = loc_811_;
								loc_814_ = loc_816_;
								loc_818_ = -2;
							end
							loc_816_ = loc_813_;
							loc_813_[1](loc_815_, loc_819_)
							loc_815_ = rt_table_get_function(loc_777_, loc_798_, "i32,i32,i32,i32->");
							loc_815_(1633, (rt_equal_i32(loc_818_, 0) and 1 or 0), loc_818_, loc_814_, loc_819_)
							loc_818_ = (rt_not_equal_i32(loc_818_, 0) and 1 or 0);
						else
							loc_816_ = loc_815_;
							loc_816_ = loc_813_;
							loc_818_ = rt_table_get_function(loc_777_, loc_798_, "i32,i32,i32,i32->");
							loc_818_(1633, 0, -1, -1, loc_819_)
							loc_818_ = 1;
						end
						loc_796_ = loc_816_;
						loc_816_[1](loc_817_, loc_819_)
						loc_806_ = loc_818_;
						loc_820_ = bit32_or(loc_820_ + loc_818_, 0);
					end
					loc_817_ = loc_788_[1](loc_791_, 1276, bit32_or(loc_779_ + 24, 0), loc_819_)
					loc_818_ = loc_788_[1](loc_791_, 1496, bit32_or(loc_779_ + 24, 0), loc_819_)
					if rt_equal_i32(loc_817_, 0) then
						loc_816_ = 0;
					else
						if rt_equal_i32(loc_818_, 0) then
							loc_816_ = 0;
						else
							rt_store_i32(loc_778_, loc_779_, 12, loc_818_)
							rt_store_i32(loc_778_, loc_779_, 8, loc_817_)
							loc_816_ = buffer_read_i32(loc_778_[1], loc_792_, 44);
							loc_783_[1](loc_793_, bit32_or(loc_779_ + 8, 0), bit32_or(loc_816_ + rt_shift_left_i32(loc_799_, 3), 0), loc_802_, loc_802_, loc_801_, loc_819_)
							rt_store_i32(loc_778_, loc_779_, 28, 0)
							loc_816_ = loc_788_[1](loc_791_, 1425, bit32_or(loc_779_ + 28, 0), loc_819_)
							if rt_not_equal_i32(loc_816_, 0) then
								loc_813_ = loc_796_;
								loc_815_ = loc_806_;
								loc_815_ = buffer_read_i32(loc_778_[1], loc_779_, 28);
								if rt_equal_i32(loc_815_, loc_775_) then
									loc_814_ = -1;
									if rt_greater_than_equal_s32(loc_802_, 1) then
										loc_811_ = 0;
										loc_815_ = 0;
										repeat
											rt_yield_budget = rt_yield_budget - 1
											if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
											loc_810_ = bit32_or(loc_811_ + 1, 0);
											if rt_less_than_s32(loc_814_, 0) then
												loc_806_ = loc_815_;
												loc_809_ = loc_775_;
												loc_775_ = loc_811_;
												loc_815_ = loc_814_;
												loc_810_, loc_814_ = loc_814_, loc_810_;
											else
												loc_806_ = loc_815_;
												loc_808_ = loc_811_;
												loc_809_ = loc_775_;
												loc_815_ = loc_814_;
												loc_810_, loc_814_ = loc_814_, loc_810_;
												loc_775_ = loc_815_;
											end
											loc_796_ = bit32_or(loc_793_ + loc_811_, 0);
											loc_774_ = rt_load_i32_from_u8(loc_778_, loc_796_, 0);
											loc_808_ = bit32_or(loc_816_ + loc_811_, 0);
											loc_815_ = rt_load_i32_from_u8(loc_778_, loc_808_, 0);
											loc_815_ = (rt_not_equal_i32(rt_and_i32(loc_774_, 255), rt_and_i32(loc_815_, 255)) and 1 or 0);
											if not (rt_not_equal_i32(loc_815_, 0)) then
												loc_775_ = loc_810_;
											end
											if rt_less_than_s32(loc_775_, 0) then
												loc_810_ = loc_775_;
											else
												loc_810_ = loc_775_;
												loc_814_ = loc_775_;
											end
											loc_796_ = rt_load_i32_from_u8(loc_778_, bit32_or(loc_796_ + 1, 0), 0);
											loc_808_ = rt_load_i32_from_u8(loc_778_, bit32_or(loc_808_ + 1, 0), 0);
											loc_808_ = (rt_not_equal_i32(loc_796_, loc_808_) and 1 or 0);
											if not (rt_not_equal_i32(loc_808_, 0)) then
												loc_814_ = loc_810_;
											end
											loc_810_ = bit32_or(loc_811_ + 2, 0);
											loc_811_ = loc_810_;
											loc_775_ = loc_809_;
											loc_815_ = bit32_or(bit32_or(loc_806_ + loc_815_, 0) + loc_808_, 0);
										until not (rt_not_equal_i32(loc_810_, loc_809_))
									else
										loc_815_ = 0;
									end
								else
									loc_814_ = loc_815_;
									loc_815_ = -2;
								end
								loc_796_ = loc_813_;
								loc_813_[1](loc_816_, loc_819_)
								loc_816_ = rt_table_get_function(loc_777_, loc_798_, "i32,i32,i32,i32->");
								loc_816_(1645, (rt_equal_i32(loc_815_, 0) and 1 or 0), loc_815_, loc_814_, loc_819_)
								loc_816_ = 2;
								loc_806_ = (rt_not_equal_i32(loc_815_, 0) and 1 or 0);
							else
								loc_813_ = loc_796_;
								loc_815_ = loc_806_;
								loc_796_ = loc_813_;
								loc_816_ = rt_table_get_function(loc_777_, loc_798_, "i32,i32,i32,i32->");
								loc_816_(1645, 0, -1, -1, loc_819_)
								loc_816_ = 1;
								loc_806_ = loc_815_;
							end
						end
					end
					if (loc_816_) >= 0 and (loc_816_) < 2 then
						if (loc_816_) < 1 then
							loc_816_ = rt_table_get_function(loc_777_, loc_798_, "i32,i32,i32,i32->");
							loc_816_(1645, 0, -1, -1, loc_819_)
							loc_816_ = 0;
						else
							loc_816_ = 0;
						end
					else
						loc_816_ = 1;
					end
					if not (rt_not_equal_i32(loc_816_, 0)) then
						loc_816_ = loc_806_;
						loc_806_ = 1;
					end
					loc_796_[1](loc_817_, loc_819_)
					loc_796_[1](loc_818_, loc_819_)
					loc_817_ = loc_788_[1](loc_791_, 1253, bit32_or(loc_779_ + 24, 0), loc_819_)
					loc_818_ = loc_788_[1](loc_791_, 1471, bit32_or(loc_779_ + 24, 0), loc_819_)
					loc_820_ = bit32_or(loc_806_ + loc_820_, 0);
					if rt_equal_i32(loc_817_, 0) then
						loc_816_ = 0;
					else
						if rt_equal_i32(loc_818_, 0) then
							loc_816_ = 0;
						else
							rt_store_i32(loc_778_, loc_779_, 12, loc_818_)
							rt_store_i32(loc_778_, loc_779_, 8, loc_817_)
							loc_816_ = buffer_read_i32(loc_778_[1], loc_792_, 60);
							loc_783_[1](loc_794_, bit32_or(loc_779_ + 8, 0), bit32_or(loc_816_ + rt_shift_left_i32(loc_799_, 3), 0), loc_802_, loc_805_, loc_801_, loc_819_)
							rt_store_i32(loc_778_, loc_779_, 28, 0)
							loc_816_ = loc_788_[1](loc_791_, 1440, bit32_or(loc_779_ + 28, 0), loc_819_)
							if rt_not_equal_i32(loc_816_, 0) then
								loc_813_ = loc_796_;
								loc_815_ = loc_806_;
								loc_815_ = buffer_read_i32(loc_778_[1], loc_779_, 28);
								if rt_equal_i32(loc_815_, loc_804_) then
									loc_814_ = -1;
									if rt_greater_than_equal_s32(loc_804_, 1) then
										loc_811_ = 0;
										loc_815_ = 0;
										repeat
											rt_yield_budget = rt_yield_budget - 1
											if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
											loc_810_ = bit32_or(loc_811_ + 1, 0);
											if rt_less_than_s32(loc_814_, 0) then
												loc_796_ = loc_811_;
												loc_806_ = loc_815_;
												loc_809_ = loc_804_;
												loc_815_ = loc_814_;
												loc_810_, loc_814_ = loc_814_, loc_810_;
											else
												loc_806_ = loc_815_;
												loc_808_ = loc_811_;
												loc_809_ = loc_804_;
												loc_815_ = loc_814_;
												loc_810_, loc_814_ = loc_814_, loc_810_;
												loc_796_ = loc_815_;
											end
											loc_804_ = bit32_or(loc_794_ + loc_811_, 0);
											loc_774_ = rt_load_i32_from_u8(loc_778_, loc_804_, 0);
											loc_808_ = bit32_or(loc_816_ + loc_811_, 0);
											loc_815_ = rt_load_i32_from_u8(loc_778_, loc_808_, 0);
											loc_815_ = (rt_not_equal_i32(rt_and_i32(loc_774_, 255), rt_and_i32(loc_815_, 255)) and 1 or 0);
											if not (rt_not_equal_i32(loc_815_, 0)) then
												loc_796_ = loc_810_;
											end
											if rt_less_than_s32(loc_796_, 0) then
												loc_810_ = loc_796_;
											else
												loc_810_ = loc_796_;
												loc_814_ = loc_796_;
											end
											loc_804_ = rt_load_i32_from_u8(loc_778_, bit32_or(loc_804_ + 1, 0), 0);
											loc_808_ = rt_load_i32_from_u8(loc_778_, bit32_or(loc_808_ + 1, 0), 0);
											loc_808_ = (rt_not_equal_i32(loc_804_, loc_808_) and 1 or 0);
											if not (rt_not_equal_i32(loc_808_, 0)) then
												loc_814_ = loc_810_;
											end
											loc_810_ = bit32_or(loc_811_ + 2, 0);
											loc_811_ = loc_810_;
											loc_804_ = loc_809_;
											loc_815_ = bit32_or(bit32_or(loc_806_ + loc_815_, 0) + loc_808_, 0);
										until not (rt_not_equal_i32(loc_810_, loc_809_))
									else
										loc_815_ = 0;
									end
								else
									loc_814_ = loc_815_;
									loc_815_ = -2;
								end
								loc_796_ = loc_813_;
								loc_813_[1](loc_816_, loc_819_)
								loc_816_ = rt_table_get_function(loc_777_, loc_798_, "i32,i32,i32,i32->");
								loc_816_(1705, (rt_equal_i32(loc_815_, 0) and 1 or 0), loc_815_, loc_814_, loc_819_)
								loc_816_ = 2;
								loc_806_ = (rt_not_equal_i32(loc_815_, 0) and 1 or 0);
							else
								loc_813_ = loc_796_;
								loc_815_ = loc_806_;
								loc_796_ = loc_813_;
								loc_816_ = rt_table_get_function(loc_777_, loc_798_, "i32,i32,i32,i32->");
								loc_816_(1705, 0, -1, -1, loc_819_)
								loc_816_ = 1;
								loc_806_ = loc_815_;
							end
						end
					end
					if (loc_816_) >= 0 and (loc_816_) < 2 then
						if (loc_816_) < 1 then
							loc_816_ = rt_table_get_function(loc_777_, loc_798_, "i32,i32,i32,i32->");
							loc_816_(1705, 0, -1, -1, loc_819_)
							loc_816_ = 0;
						else
							loc_816_ = 0;
						end
					else
						loc_816_ = 1;
					end
					if not (rt_not_equal_i32(loc_816_, 0)) then
						loc_816_ = loc_806_;
						loc_806_ = 1;
					end
					loc_796_[1](loc_817_, loc_819_)
					loc_796_[1](loc_818_, loc_819_)
					loc_814_ = loc_788_[1](loc_791_, 1535, bit32_or(loc_779_ + 24, 0), loc_819_)
					loc_815_ = loc_788_[1](loc_791_, 1564, bit32_or(loc_779_ + 24, 0), loc_819_)
					loc_813_ = bit32_or(loc_820_ + loc_806_, 0);
					if rt_equal_i32(loc_814_, 0) then
						loc_811_ = 0;
					else
						if rt_equal_i32(loc_815_, 0) then
							loc_811_ = 0;
						else
							loc_819_ = loc_812_;
							loc_820_ = loc_806_;
							loc_817_ = buffer_read_i32(loc_778_[1], loc_792_, 188);
							loc_820_ = rt_divide_s32(loc_807_, 2);
							loc_818_ = rt_shift_left_i32(rt_multiply_i32(loc_790_, loc_820_), 2);
							loc_819_ = buffer_read_i32(loc_778_[1], loc_792_, 192);
							loc_816_, loc_820_ = loc_820_, loc_816_;
							loc_784_[1](loc_814_, loc_815_, bit32_or(loc_817_ + loc_818_, 0), bit32_or(loc_819_ + loc_818_, 0), loc_802_, loc_800_, loc_807_, loc_820_)
							rt_store_i32(loc_778_, loc_779_, 8, 0)
							loc_817_ = loc_788_[1](loc_791_, 1352, bit32_or(loc_779_ + 8, 0), loc_820_)
							if rt_not_equal_i32(loc_817_, 0) then
								loc_819_ = loc_813_;
								loc_813_ = loc_796_;
								loc_820_ = buffer_read_i32(loc_778_[1], loc_779_, 8);
								if rt_equal_i32(loc_820_, loc_775_) then
									loc_816_ = -1;
									if rt_greater_than_equal_s32(loc_802_, 1) then
										loc_812_ = 0;
										loc_820_ = 0;
										repeat
											rt_yield_budget = rt_yield_budget - 1
											if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
											loc_811_ = bit32_or(loc_812_ + 1, 0);
											if rt_less_than_s32(loc_816_, 0) then
												loc_796_ = loc_812_;
												loc_808_ = loc_820_;
												loc_810_ = loc_775_;
												loc_820_ = loc_816_;
												loc_811_, loc_816_ = loc_816_, loc_811_;
											else
												loc_808_ = loc_820_;
												loc_809_ = loc_812_;
												loc_810_ = loc_775_;
												loc_820_ = loc_816_;
												loc_811_, loc_816_ = loc_816_, loc_811_;
												loc_796_ = loc_820_;
											end
											loc_806_ = bit32_or(loc_814_ + loc_812_, 0);
											loc_775_ = rt_load_i32_from_u8(loc_778_, loc_806_, 0);
											loc_809_ = bit32_or(loc_817_ + loc_812_, 0);
											loc_820_ = rt_load_i32_from_u8(loc_778_, loc_809_, 0);
											loc_820_ = (rt_not_equal_i32(rt_and_i32(loc_775_, 255), rt_and_i32(loc_820_, 255)) and 1 or 0);
											if not (rt_not_equal_i32(loc_820_, 0)) then
												loc_796_ = loc_811_;
											end
											if rt_less_than_s32(loc_796_, 0) then
												loc_811_ = loc_796_;
											else
												loc_811_ = loc_796_;
												loc_816_ = loc_796_;
											end
											loc_806_ = rt_load_i32_from_u8(loc_778_, bit32_or(loc_806_ + 1, 0), 0);
											loc_809_ = rt_load_i32_from_u8(loc_778_, bit32_or(loc_809_ + 1, 0), 0);
											loc_809_ = (rt_not_equal_i32(loc_806_, loc_809_) and 1 or 0);
											if not (rt_not_equal_i32(loc_809_, 0)) then
												loc_816_ = loc_811_;
											end
											loc_811_ = bit32_or(loc_812_ + 2, 0);
											loc_812_ = loc_811_;
											loc_775_ = loc_810_;
											loc_820_ = bit32_or(bit32_or(loc_808_ + loc_820_, 0) + loc_809_, 0);
										until not (rt_not_equal_i32(loc_811_, loc_810_))
									else
										loc_820_ = 0;
									end
								else
									loc_816_ = loc_820_;
									loc_820_ = -2;
								end
								loc_808_ = loc_813_;
								loc_813_[1](loc_817_, loc_818_)
								loc_817_ = rt_table_get_function(loc_777_, loc_798_, "i32,i32,i32,i32->");
								loc_817_(1671, (rt_equal_i32(loc_820_, 0) and 1 or 0), loc_820_, loc_816_, loc_818_)
								loc_820_ = (rt_not_equal_i32(loc_820_, 0) and 1 or 0);
							else
								loc_819_ = loc_813_;
								loc_813_ = loc_796_;
								loc_820_ = loc_818_;
								loc_818_ = loc_817_;
								loc_808_ = loc_813_;
								loc_818_ = rt_table_get_function(loc_777_, loc_798_, "i32,i32,i32,i32->");
								loc_818_(1671, 0, -1, -1, loc_820_)
								loc_820_ = 1;
							end
							rt_store_i32(loc_778_, loc_779_, 8, 0)
							loc_811_ = loc_788_[1](loc_791_, 1396, bit32_or(loc_779_ + 8, 0), loc_818_)
							loc_812_ = bit32_or(loc_820_ + loc_819_, 0);
							if rt_not_equal_i32(loc_811_, 0) then
								loc_819_ = buffer_read_i32(loc_778_[1], loc_779_, 8);
								loc_813_ = rt_shift_left_i32(loc_800_, 2);
								if rt_equal_i32(loc_819_, loc_813_) then
									loc_809_ = -1;
									if rt_greater_than_equal_s32(loc_800_, 1) then
										loc_806_ = 0;
										loc_810_ = 0;
										repeat
											rt_yield_budget = rt_yield_budget - 1
											if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
											loc_820_ = bit32_or(loc_806_ + 1, 0);
											if rt_less_than_s32(loc_809_, 0) then
												loc_774_ = loc_813_;
												loc_796_ = loc_809_;
												loc_817_ = loc_810_;
												loc_819_ = loc_806_;
												loc_809_, loc_820_ = loc_820_, loc_809_;
											else
												loc_774_ = loc_813_;
												loc_796_ = loc_809_;
												loc_817_ = loc_810_;
												loc_819_ = loc_806_;
												loc_809_, loc_820_ = loc_820_, loc_809_;
												loc_819_ = loc_820_;
											end
											loc_818_ = bit32_or(loc_815_ + loc_806_, 0);
											loc_820_ = rt_load_i32_from_u8(loc_778_, loc_818_, 0);
											loc_810_ = bit32_or(loc_811_ + loc_806_, 0);
											loc_813_ = rt_load_i32_from_u8(loc_778_, loc_810_, 0);
											loc_813_ = (rt_not_equal_i32(rt_and_i32(loc_820_, 255), rt_and_i32(loc_813_, 255)) and 1 or 0);
											if not (rt_not_equal_i32(loc_813_, 0)) then
												loc_819_ = loc_796_;
											end
											if rt_less_than_s32(loc_819_, 0) then
												loc_796_ = loc_819_;
											else
												loc_796_ = loc_819_;
												loc_809_ = loc_819_;
											end
											loc_818_ = rt_load_i32_from_u8(loc_778_, bit32_or(loc_818_ + 1, 0), 0);
											loc_810_ = rt_load_i32_from_u8(loc_778_, bit32_or(loc_810_ + 1, 0), 0);
											loc_810_ = (rt_not_equal_i32(loc_818_, loc_810_) and 1 or 0);
											if not (rt_not_equal_i32(loc_810_, 0)) then
												loc_809_ = loc_796_;
											end
											loc_796_ = bit32_or(loc_806_ + 2, 0);
											loc_806_ = loc_796_;
											loc_810_ = bit32_or(bit32_or(loc_817_ + loc_813_, 0) + loc_810_, 0);
											loc_813_ = loc_774_;
										until not (rt_not_equal_i32(loc_796_, loc_774_))
									else
										loc_806_ = loc_820_;
										loc_810_ = 0;
									end
								else
									loc_806_ = loc_820_;
									loc_809_ = loc_819_;
									loc_810_ = -2;
								end
								loc_796_ = loc_808_;
								loc_808_[1](loc_811_, loc_816_)
								loc_811_ = rt_table_get_function(loc_777_, loc_798_, "i32,i32,i32,i32->");
								loc_811_(1686, (rt_equal_i32(loc_810_, 0) and 1 or 0), loc_810_, loc_809_, loc_816_)
								loc_811_ = 1;
								loc_812_ = bit32_or(loc_812_ + (rt_not_equal_i32(loc_810_, 0) and 1 or 0), 0);
							else
								loc_818_ = loc_811_;
								loc_796_ = loc_808_;
								loc_817_ = rt_table_get_function(loc_777_, loc_798_, "i32,i32,i32,i32->");
								loc_818_ = loc_816_;
								loc_817_(1686, 0, -1, -1, loc_818_)
								loc_811_ = 1;
								loc_806_ = loc_820_;
								loc_813_ = loc_819_;
								loc_812_ = bit32_or(loc_812_ + 1, 0);
							end
						end
					end
					if not (rt_not_equal_i32(loc_811_, 0)) then
						loc_812_ = rt_table_get_function(loc_777_, loc_798_, "i32,i32,i32,i32->");
						loc_812_(1215, 0, -1, -1, loc_816_)
						loc_812_ = bit32_or(loc_813_ + 1, 0);
					end
					loc_796_[1](loc_814_, loc_816_)
					loc_796_[1](loc_815_, loc_816_)
					loc_808_ = loc_788_[1](loc_791_, 1509, bit32_or(loc_779_ + 24, 0), loc_816_)
					loc_809_ = loc_788_[1](loc_791_, 1594, bit32_or(loc_779_ + 24, 0), loc_816_)
					loc_810_ = loc_788_[1](loc_791_, 1297, bit32_or(loc_779_ + 24, 0), loc_816_)
					if rt_equal_i32(loc_808_, 0) then
						loc_807_ = 0;
					else
						if rt_equal_i32(loc_809_, 0) then
							loc_807_ = 0;
						else
							if rt_equal_i32(loc_810_, 0) then
								loc_807_ = 0;
							else
								loc_813_ = loc_807_;
								loc_816_ = loc_806_;
								loc_814_ = buffer_read_i32(loc_778_[1], loc_792_, 12);
								loc_815_ = buffer_read_i32(loc_778_[1], loc_792_, 24);
								loc_816_ = loc_811_;
								loc_807_ = loc_789_[1](rt_shift_left_i32(rt_multiply_i32(loc_814_, loc_815_), 2), loc_816_)
								loc_785_[1](loc_793_, loc_808_, loc_809_, loc_810_, loc_807_, loc_799_, loc_790_, loc_814_, loc_813_, loc_800_, loc_803_, loc_815_, loc_816_)
								rt_store_i32(loc_778_, loc_779_, 8, 0)
								loc_800_ = loc_788_[1](loc_791_, 1367, bit32_or(loc_779_ + 8, 0), loc_816_)
								if rt_not_equal_i32(loc_800_, 0) then
									loc_790_ = loc_775_;
									loc_803_ = loc_796_;
									loc_816_ = buffer_read_i32(loc_778_[1], loc_779_, 8);
									if rt_equal_i32(loc_816_, loc_790_) then
										loc_799_ = -1;
										if rt_greater_than_equal_s32(loc_802_, 1) then
											loc_796_ = 0;
											loc_806_ = 0;
											repeat
												rt_yield_budget = rt_yield_budget - 1
												if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
												loc_816_ = bit32_or(loc_796_ + 1, 0);
												if rt_less_than_s32(loc_799_, 0) then
													loc_774_ = loc_790_;
													loc_790_ = loc_799_;
													loc_814_ = loc_806_;
													loc_815_ = loc_796_;
													loc_799_, loc_816_ = loc_816_, loc_799_;
												else
													loc_774_ = loc_790_;
													loc_790_ = loc_799_;
													loc_814_ = loc_806_;
													loc_815_ = loc_796_;
													loc_799_, loc_816_ = loc_816_, loc_799_;
													loc_815_ = loc_816_;
												end
												loc_775_ = bit32_or(loc_793_ + loc_796_, 0);
												loc_816_ = rt_load_i32_from_u8(loc_778_, loc_775_, 0);
												loc_813_ = bit32_or(loc_800_ + loc_796_, 0);
												loc_806_ = rt_load_i32_from_u8(loc_778_, loc_813_, 0);
												loc_806_ = (rt_not_equal_i32(rt_and_i32(loc_816_, 255), rt_and_i32(loc_806_, 255)) and 1 or 0);
												if not (rt_not_equal_i32(loc_806_, 0)) then
													loc_815_ = loc_790_;
												end
												if rt_less_than_s32(loc_815_, 0) then
													loc_790_ = loc_815_;
												else
													loc_790_ = loc_815_;
													loc_799_ = loc_815_;
												end
												loc_775_ = rt_load_i32_from_u8(loc_778_, bit32_or(loc_775_ + 1, 0), 0);
												loc_813_ = rt_load_i32_from_u8(loc_778_, bit32_or(loc_813_ + 1, 0), 0);
												loc_813_ = (rt_not_equal_i32(loc_775_, loc_813_) and 1 or 0);
												if not (rt_not_equal_i32(loc_813_, 0)) then
													loc_799_ = loc_790_;
												end
												loc_775_ = bit32_or(loc_796_ + 2, 0);
												loc_796_ = loc_775_;
												loc_790_ = loc_774_;
												loc_806_ = bit32_or(bit32_or(loc_814_ + loc_806_, 0) + loc_813_, 0);
											until not (rt_not_equal_i32(loc_775_, loc_774_))
										else
											loc_816_ = loc_790_;
											loc_806_ = 0;
										end
									else
										loc_815_ = loc_790_;
										loc_799_ = loc_816_;
										loc_806_ = -2;
									end
									loc_796_ = loc_803_;
									loc_803_[1](loc_800_, loc_811_)
									loc_800_ = rt_table_get_function(loc_777_, loc_798_, "i32,i32,i32,i32->");
									loc_800_(1092, (rt_equal_i32(loc_806_, 0) and 1 or 0), loc_806_, loc_799_, loc_811_)
									loc_803_[1](loc_807_, loc_811_)
									loc_807_ = 1;
									loc_806_ = (rt_not_equal_i32(loc_806_, 0) and 1 or 0);
								else
									loc_803_ = loc_796_;
									loc_815_ = loc_800_;
									loc_816_ = loc_775_;
									loc_796_ = loc_803_;
									loc_815_ = rt_table_get_function(loc_777_, loc_798_, "i32,i32,i32,i32->");
									loc_816_ = loc_811_;
									loc_815_(1092, 0, -1, -1, loc_816_)
									loc_803_[1](loc_807_, loc_816_)
									loc_807_ = 1;
									loc_806_ = 1;
								end
							end
						end
					end
					if not (rt_not_equal_i32(loc_807_, 0)) then
						loc_807_ = loc_806_;
						loc_807_ = rt_table_get_function(loc_777_, loc_798_, "i32,i32,i32,i32->");
						loc_807_(1092, 0, -1, -1, loc_811_)
						loc_806_ = 1;
					end
					loc_796_[1](loc_808_, loc_811_)
					loc_796_[1](loc_809_, loc_811_)
					loc_796_[1](loc_810_, loc_811_)
					loc_807_ = loc_788_[1](loc_791_, 1618, bit32_or(loc_779_ + 24, 0), loc_811_)
					loc_808_ = loc_788_[1](loc_791_, 1605, bit32_or(loc_779_ + 24, 0), loc_811_)
					loc_810_ = bit32_or(loc_806_ + loc_812_, 0);
					if rt_equal_i32(loc_807_, 0) then
						loc_805_ = 0;
					else
						if rt_equal_i32(loc_808_, 0) then
							loc_805_ = 0;
						else
							loc_812_ = loc_809_;
							loc_786_[1](loc_807_, loc_808_, loc_805_, loc_812_)
							rt_store_i32(loc_778_, loc_779_, 8, 0)
							loc_805_ = loc_788_[1](loc_791_, 1324, bit32_or(loc_779_ + 8, 0), loc_812_)
							if rt_not_equal_i32(loc_805_, 0) then
								loc_799_ = loc_804_;
								loc_803_ = loc_796_;
								loc_812_ = loc_806_;
								loc_812_ = buffer_read_i32(loc_778_[1], loc_779_, 8);
								if rt_equal_i32(loc_812_, loc_799_) then
									loc_804_ = -1;
									if rt_greater_than_equal_s32(loc_799_, 1) then
										loc_800_ = 0;
										loc_806_ = 0;
										repeat
											rt_yield_budget = rt_yield_budget - 1
											if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
											loc_812_ = bit32_or(loc_800_ + 1, 0);
											if rt_less_than_s32(loc_804_, 0) then
												loc_774_ = loc_806_;
												loc_790_ = loc_799_;
												loc_799_ = loc_804_;
												loc_811_ = loc_800_;
												loc_804_, loc_812_ = loc_812_, loc_804_;
											else
												loc_774_ = loc_806_;
												loc_790_ = loc_799_;
												loc_799_ = loc_804_;
												loc_811_ = loc_800_;
												loc_804_, loc_812_ = loc_812_, loc_804_;
												loc_811_ = loc_812_;
											end
											loc_775_ = bit32_or(loc_807_ + loc_800_, 0);
											loc_812_ = rt_load_i32_from_u8(loc_778_, loc_775_, 0);
											loc_796_ = bit32_or(loc_805_ + loc_800_, 0);
											loc_806_ = rt_load_i32_from_u8(loc_778_, loc_796_, 0);
											loc_806_ = (rt_not_equal_i32(rt_and_i32(loc_812_, 255), rt_and_i32(loc_806_, 255)) and 1 or 0);
											if not (rt_not_equal_i32(loc_806_, 0)) then
												loc_811_ = loc_799_;
											end
											if rt_less_than_s32(loc_811_, 0) then
												loc_799_ = loc_811_;
											else
												loc_799_ = loc_811_;
												loc_804_ = loc_811_;
											end
											loc_775_ = rt_load_i32_from_u8(loc_778_, bit32_or(loc_775_ + 1, 0), 0);
											loc_796_ = rt_load_i32_from_u8(loc_778_, bit32_or(loc_796_ + 1, 0), 0);
											loc_775_ = (rt_not_equal_i32(loc_775_, loc_796_) and 1 or 0);
											if not (rt_not_equal_i32(loc_775_, 0)) then
												loc_804_ = loc_799_;
											end
											loc_796_ = bit32_or(loc_800_ + 2, 0);
											loc_800_ = loc_796_;
											loc_799_ = loc_790_;
											loc_806_ = bit32_or(bit32_or(loc_774_ + loc_806_, 0) + loc_775_, 0);
										until not (rt_not_equal_i32(loc_796_, loc_790_))
									else
										loc_812_ = loc_799_;
										loc_806_ = 0;
									end
								else
									loc_811_ = loc_799_;
									loc_804_ = loc_812_;
									loc_806_ = -2;
								end
								loc_796_ = loc_803_;
								loc_803_[1](loc_805_, loc_809_)
								loc_805_ = rt_table_get_function(loc_777_, loc_798_, "i32,i32,i32,i32->");
								loc_805_(1193, (rt_equal_i32(loc_806_, 0) and 1 or 0), loc_806_, loc_804_, loc_809_)
								loc_805_ = 2;
								loc_806_ = (rt_not_equal_i32(loc_806_, 0) and 1 or 0);
							else
								loc_803_ = loc_796_;
								loc_811_ = loc_809_;
								loc_809_ = loc_804_;
								loc_812_ = loc_806_;
								loc_806_ = loc_805_;
								loc_796_ = loc_803_;
								loc_809_ = rt_table_get_function(loc_777_, loc_798_, "i32,i32,i32,i32->");
								loc_809_(1193, 0, -1, -1, loc_811_)
								loc_805_ = 1;
								loc_806_ = loc_812_;
							end
						end
					end
					if (loc_805_) >= 0 and (loc_805_) < 2 then
						if (loc_805_) < 1 then
							loc_805_ = rt_table_get_function(loc_777_, loc_798_, "i32,i32,i32,i32->");
							loc_805_(1193, 0, -1, -1, loc_809_)
							loc_805_ = 0;
						else
							loc_805_ = 0;
						end
					else
						loc_805_ = 1;
					end
					if not (rt_not_equal_i32(loc_805_, 0)) then
						loc_806_ = 1;
					end
					loc_796_[1](loc_807_, loc_809_)
					loc_796_[1](loc_808_, loc_809_)
					loc_803_ = loc_788_[1](loc_791_, 1241, bit32_or(loc_779_ + 24, 0), loc_809_)
					loc_804_ = loc_788_[1](loc_791_, 1458, bit32_or(loc_779_ + 24, 0), loc_809_)
					loc_807_ = bit32_or(loc_810_ + loc_806_, 0);
					if rt_equal_i32(loc_803_, 0) then
						loc_802_ = 0;
					else
						if rt_equal_i32(loc_804_, 0) then
							loc_802_ = 0;
						else
							loc_810_ = loc_806_;
							rt_store_i32(loc_778_, loc_779_, 12, loc_804_)
							rt_store_i32(loc_778_, loc_779_, 8, loc_803_)
							loc_808_ = buffer_read_i32(loc_778_[1], loc_792_, 72);
							loc_809_ = buffer_read_i32(loc_778_[1], loc_792_, 20);
							loc_810_ = loc_805_;
							loc_783_[1](loc_793_, bit32_or(loc_779_ + 8, 0), loc_808_, loc_802_, loc_809_, loc_801_, loc_810_)
							loc_810_ = buffer_read_i32(loc_778_[1], loc_792_, 20);
							rt_store_i32(loc_778_, loc_779_, 28, 0)
							loc_802_ = loc_788_[1](loc_791_, 1337, bit32_or(loc_779_ + 28, 0), loc_809_)
							if rt_not_equal_i32(loc_802_, 0) then
								loc_800_ = loc_796_;
								loc_809_ = buffer_read_i32(loc_778_[1], loc_779_, 28);
								loc_796_ = rt_shift_left_i32(loc_810_, 2);
								if rt_equal_i32(loc_809_, loc_796_) then
									loc_801_ = -1;
									if rt_greater_than_equal_s32(loc_810_, 1) then
										loc_799_ = 0;
										loc_806_ = 0;
										repeat
											rt_yield_budget = rt_yield_budget - 1
											if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
											loc_810_ = bit32_or(loc_799_ + 1, 0);
											if rt_less_than_s32(loc_801_, 0) then
												loc_775_ = loc_796_;
												loc_796_ = loc_801_;
												loc_808_ = loc_806_;
												loc_809_ = loc_799_;
												loc_801_, loc_810_ = loc_810_, loc_801_;
											else
												loc_775_ = loc_796_;
												loc_796_ = loc_801_;
												loc_808_ = loc_806_;
												loc_809_ = loc_799_;
												loc_801_, loc_810_ = loc_810_, loc_801_;
												loc_809_ = loc_810_;
											end
											loc_774_ = bit32_or(loc_793_ + loc_799_, 0);
											loc_810_ = rt_load_i32_from_u8(loc_778_, loc_774_, 0);
											loc_790_ = bit32_or(loc_802_ + loc_799_, 0);
											loc_806_ = rt_load_i32_from_u8(loc_778_, loc_790_, 0);
											loc_806_ = (rt_not_equal_i32(rt_and_i32(loc_810_, 255), rt_and_i32(loc_806_, 255)) and 1 or 0);
											if not (rt_not_equal_i32(loc_806_, 0)) then
												loc_809_ = loc_796_;
											end
											if rt_less_than_s32(loc_809_, 0) then
												loc_796_ = loc_809_;
											else
												loc_796_ = loc_809_;
												loc_801_ = loc_809_;
											end
											loc_774_ = rt_load_i32_from_u8(loc_778_, bit32_or(loc_774_ + 1, 0), 0);
											loc_790_ = rt_load_i32_from_u8(loc_778_, bit32_or(loc_790_ + 1, 0), 0);
											loc_774_ = (rt_not_equal_i32(loc_774_, loc_790_) and 1 or 0);
											if not (rt_not_equal_i32(loc_774_, 0)) then
												loc_801_ = loc_796_;
											end
											loc_790_ = bit32_or(loc_799_ + 2, 0);
											loc_799_ = loc_790_;
											loc_796_ = loc_775_;
											loc_806_ = bit32_or(bit32_or(loc_808_ + loc_806_, 0) + loc_774_, 0);
										until not (rt_not_equal_i32(loc_790_, loc_775_))
									else
										loc_810_ = loc_796_;
										loc_806_ = 0;
									end
								else
									loc_808_ = loc_796_;
									loc_801_ = loc_809_;
									loc_806_ = -2;
								end
								loc_796_ = loc_800_;
								loc_800_[1](loc_802_, loc_805_)
								loc_802_ = rt_table_get_function(loc_777_, loc_798_, "i32,i32,i32,i32->");
								loc_802_(1061, (rt_equal_i32(loc_806_, 0) and 1 or 0), loc_806_, loc_801_, loc_805_)
								loc_802_ = 2;
								loc_806_ = (rt_not_equal_i32(loc_806_, 0) and 1 or 0);
							else
								loc_800_ = loc_796_;
								loc_809_ = loc_802_;
								loc_796_ = loc_800_;
								loc_808_ = rt_table_get_function(loc_777_, loc_798_, "i32,i32,i32,i32->");
								loc_809_ = loc_805_;
								loc_808_(1061, 0, -1, -1, loc_809_)
								loc_802_ = 1;
								loc_806_ = loc_810_;
							end
						end
					end
					if (loc_802_) >= 0 and (loc_802_) < 2 then
						if (loc_802_) < 1 then
							loc_802_ = rt_table_get_function(loc_777_, loc_798_, "i32,i32,i32,i32->");
							loc_802_(1061, 0, -1, -1, loc_805_)
							loc_802_ = 0;
						else
							loc_802_ = 0;
						end
					else
						loc_802_ = 1;
					end
					if not (rt_not_equal_i32(loc_802_, 0)) then
						loc_806_ = 1;
					end
					loc_796_[1](loc_803_, loc_805_)
					loc_796_[1](loc_804_, loc_805_)
					loc_790_ = loc_788_[1](loc_791_, 1520, bit32_or(loc_779_ + 24, 0), loc_805_)
					loc_800_ = bit32_or(loc_807_ + loc_806_, 0);
					if rt_equal_i32(loc_790_, 0) then
						loc_798_ = rt_table_get_function(loc_777_, loc_798_, "i32,i32,i32,i32->");
						loc_798_(1024, 0, -1, -1, loc_799_)
						loc_799_ = 1;
					else
						loc_806_ = buffer_read_i32(loc_778_[1], loc_792_, 20);
						loc_807_ = loc_799_;
						loc_787_[1](loc_790_, loc_806_, loc_807_)
						loc_807_ = buffer_read_i32(loc_778_[1], loc_792_, 20);
						rt_store_i32(loc_778_, loc_779_, 8, 0)
						loc_774_ = loc_788_[1](loc_791_, 1308, bit32_or(loc_779_ + 8, 0), loc_806_)
						if rt_not_equal_i32(loc_774_, 0) then
							loc_791_ = loc_796_;
							loc_792_ = loc_790_;
							loc_790_ = loc_798_;
							loc_798_ = loc_806_;
							loc_806_ = buffer_read_i32(loc_778_[1], loc_779_, 8);
							loc_801_ = rt_shift_left_i32(loc_807_, 2);
							if rt_equal_i32(loc_806_, loc_801_) then
								loc_775_ = -1;
								if rt_greater_than_equal_s32(loc_807_, 1) then
									loc_796_ = 0;
									loc_799_ = 0;
									repeat
										rt_yield_budget = rt_yield_budget - 1
										if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
										loc_807_ = bit32_or(loc_796_ + 1, 0);
										if rt_less_than_s32(loc_775_, 0) then
											loc_802_ = loc_796_;
											loc_803_ = loc_801_;
											loc_804_ = loc_799_;
											loc_806_ = loc_796_;
											loc_796_ = loc_775_;
											loc_775_, loc_807_ = loc_807_, loc_775_;
										else
											loc_802_ = loc_796_;
											loc_803_ = loc_801_;
											loc_804_ = loc_799_;
											loc_806_ = loc_796_;
											loc_796_ = loc_775_;
											loc_775_, loc_807_ = loc_807_, loc_775_;
											loc_806_ = loc_807_;
										end
										loc_805_ = bit32_or(loc_792_ + loc_802_, 0);
										loc_807_ = rt_load_i32_from_u8(loc_778_, loc_805_, 0);
										loc_799_ = bit32_or(loc_774_ + loc_802_, 0);
										loc_801_ = rt_load_i32_from_u8(loc_778_, loc_799_, 0);
										loc_801_ = (rt_not_equal_i32(rt_and_i32(loc_807_, 255), rt_and_i32(loc_801_, 255)) and 1 or 0);
										if not (rt_not_equal_i32(loc_801_, 0)) then
											loc_806_ = loc_796_;
										end
										if rt_less_than_s32(loc_806_, 0) then
											loc_796_ = loc_806_;
										else
											loc_796_ = loc_806_;
											loc_775_ = loc_806_;
										end
										loc_805_ = rt_load_i32_from_u8(loc_778_, bit32_or(loc_805_ + 1, 0), 0);
										loc_799_ = rt_load_i32_from_u8(loc_778_, bit32_or(loc_799_ + 1, 0), 0);
										loc_799_ = (rt_not_equal_i32(loc_805_, loc_799_) and 1 or 0);
										if not (rt_not_equal_i32(loc_799_, 0)) then
											loc_775_ = loc_796_;
										end
										loc_802_ = bit32_or(loc_802_ + 2, 0);
										loc_796_ = loc_802_;
										loc_799_ = bit32_or(bit32_or(loc_804_ + loc_801_, 0) + loc_799_, 0);
										loc_801_ = loc_803_;
									until not (rt_not_equal_i32(loc_802_, loc_803_))
								else
									loc_807_ = loc_801_;
									loc_799_ = 0;
								end
							else
								loc_805_ = loc_801_;
								loc_775_ = loc_806_;
								loc_799_ = -2;
							end
							loc_796_ = loc_791_;
							loc_791_[1](loc_774_, loc_798_)
							loc_790_ = rt_table_get_function(loc_777_, loc_790_, "i32,i32,i32,i32->");
							loc_790_(1024, (rt_equal_i32(loc_799_, 0) and 1 or 0), loc_799_, loc_775_, loc_798_)
							loc_791_[1](loc_792_, loc_798_)
							loc_799_ = (rt_not_equal_i32(loc_799_, 0) and 1 or 0);
						else
							loc_791_ = loc_796_;
							loc_792_ = loc_790_;
							loc_790_ = loc_798_;
							loc_798_ = loc_806_;
							loc_806_ = loc_774_;
							loc_796_ = loc_791_;
							loc_806_ = rt_table_get_function(loc_777_, loc_790_, "i32,i32,i32,i32->");
							loc_807_ = loc_798_;
							loc_806_(1024, 0, -1, -1, loc_807_)
							loc_791_[1](loc_792_, loc_807_)
							loc_799_ = 1;
						end
					end
					loc_790_ = loc_796_;
					loc_796_[1](loc_793_, loc_798_)
					loc_796_[1](loc_794_, loc_798_)
					loc_796_[1](loc_795_, loc_798_)
					loc_796_[1](loc_797_, loc_798_)
					loc_791_ = 1;
					loc_775_ = bit32_or(loc_800_ + loc_799_, 0);
				else
					loc_808_ = loc_800_;
					loc_809_ = loc_799_;
					loc_810_ = loc_798_;
					loc_811_ = loc_797_;
					loc_812_ = loc_796_;
					loc_813_ = loc_795_;
					loc_814_ = loc_794_;
					loc_815_ = loc_793_;
					loc_816_ = loc_790_;
					loc_817_ = loc_792_;
					loc_818_ = loc_791_;
					loc_819_ = loc_775_;
					loc_820_ = loc_774_;
					loc_790_ = loc_816_;
					loc_791_ = 0;
					loc_775_ = loc_819_;
					loc_774_ = loc_820_;
				end
			end
			if not (rt_not_equal_i32(loc_791_, 0)) then
				loc_791_ = loc_790_;
				loc_790_ = loc_791_;
				loc_791_[1](loc_775_, loc_774_)
				loc_775_ = -1;
			end
			loc_776_[1] = bit32_or(loc_779_ + 32, 0);
			return loc_775_, loc_774_
		end), "i32,i32,i32->i32")
	end)(module_locals[50], module_locals[51], module_locals[52], module_locals[53], module_locals[54], module_locals[55], module_locals[57], module_locals[59], module_locals[63], module_locals[156], module_locals[159], module_locals[164], module_locals[162], module_locals[3]);
	do (function() --[[spider:chunk]]
	module_locals[127] = { nil };
	module_locals[63][1] = (function(loc_821_, loc_822_, loc_823_, loc_824_, loc_825_, loc_826_, loc_827_, loc_828_, loc_829_, loc_830_)
		return rt_function_type(--[[fn:st_read]](function(loc_831_, loc_832_, loc_833_, loc_834_)
			local loc_835_, loc_836_, loc_837_, loc_838_, loc_839_, loc_840_, loc_841_, loc_842_, loc_843_, loc_844_, loc_845_, loc_846_, loc_847_, loc_848_, loc_849_, loc_850_, loc_851_, loc_852_
			loc_852_ = loc_829_[1];
			loc_837_ = loc_829_;
			loc_839_ = bit32_or(loc_852_ - 1040, 0);
			loc_837_[1] = loc_839_;
			rt_store_i32(loc_830_, loc_839_, 0, loc_831_)
			loc_838_ = loc_830_;
			rt_store_i32(loc_838_, loc_839_, 4, loc_832_)
			loc_852_ = loc_834_;
			loc_851_ = loc_826_[1](bit32_or(loc_839_ + 16, 0), 1024, 1086, loc_839_, loc_852_)
			loc_835_ = loc_822_[1](bit32_or(loc_839_ + 16, 0), 1226, loc_852_)
			if rt_not_equal_i32(loc_835_, 0) then
				loc_840_ = loc_821_;
				loc_841_ = loc_822_;
				loc_842_ = loc_823_;
				loc_843_ = loc_824_;
				loc_844_ = loc_825_;
				loc_845_ = loc_826_;
				loc_846_ = loc_827_;
				loc_847_ = loc_828_;
				loc_848_ = loc_833_;
				loc_851_ = loc_843_[1](loc_835_, 0, 2, loc_852_)
				loc_851_ = loc_844_[1](loc_835_, loc_852_)
				loc_850_ = loc_843_[1](loc_835_, 0, 0, loc_852_)
				loc_850_ = 0;
				loc_836_ = 1;
				if rt_greater_than_s32(loc_851_, 1) then
					loc_849_ = loc_851_;
				else
					loc_849_ = loc_851_;
					loc_851_ = loc_836_;
				end
				loc_836_ = loc_846_[1](loc_851_, loc_852_)
				loc_851_ = loc_842_[1](loc_836_, 1, loc_849_, loc_835_, loc_852_)
				loc_852_ = loc_840_[1](loc_835_, loc_852_)
				if rt_equal_i32(loc_851_, loc_849_) then
					rt_store_i32(loc_838_, loc_848_, 0, loc_849_)
				else
					loc_847_, loc_848_ = loc_848_, loc_847_;
					loc_847_ = loc_848_;
					loc_849_ = loc_835_;
					loc_848_[1](loc_836_, loc_849_)
					loc_836_ = loc_850_;
				end
			else
				loc_840_ = loc_821_;
				loc_841_ = loc_822_;
				loc_842_ = loc_823_;
				loc_843_ = loc_824_;
				loc_844_ = loc_825_;
				loc_845_ = loc_826_;
				loc_846_ = loc_827_;
				loc_847_ = loc_828_;
				loc_850_ = loc_833_;
				loc_851_ = loc_835_;
				loc_836_ = 0;
				loc_835_ = loc_852_;
			end
			loc_837_[1] = bit32_or(loc_839_ + 1040, 0);
			return loc_836_, loc_835_
		end), "i32,i32,i32->i32")
	end)(module_locals[90], module_locals[111], module_locals[114], module_locals[115], module_locals[116], module_locals[127], module_locals[156], module_locals[159], module_locals[164], module_locals[3]);
	module_locals[64] = { nil };
	module_locals[134] = { nil };
	end)() end --[[/spider:chunk]]
	module_locals[64][1] = (function(loc_853_, loc_854_, loc_855_, loc_856_, loc_857_)
		return rt_function_type(--[[fn:sample_token]](function(loc_858_, loc_859_, loc_860_, loc_861_, loc_862_, loc_863_)
			local loc_864_, loc_865_, loc_866_, loc_867_, loc_868_, loc_869_, loc_870_, loc_871_, loc_872_, loc_873_, loc_874_, loc_875_, loc_876_, loc_877_, loc_878_, loc_879_, loc_880_, loc_881_, loc_882_, loc_883_, loc_884_, loc_885_, loc_886_, loc_887_
			loc_884_ = 0;
			loc_880_ = 0;
			if rt_less_than_equal_f32(loc_860_, 0 --[[ 0_f32 ]]) then
				loc_864_ = loc_863_;
				loc_865_ = loc_858_;
				loc_866_ = loc_857_;
				loc_867_ = loc_853_;
				loc_868_ = loc_854_;
				loc_869_ = loc_855_;
				loc_870_ = loc_856_;
				loc_872_ = loc_859_;
				loc_881_ = loc_862_;
				loc_882_ = loc_861_;
				loc_883_ = loc_860_;
				loc_871_ = 0;
				if rt_less_than_s32(loc_872_, 2) then
					loc_872_ = 0;
				else
					loc_883_ = loc_872_;
					loc_884_ = loc_871_;
					loc_872_ = rt_load_f32(loc_866_, loc_865_, 0);
					loc_884_ = bit32_or(loc_883_ + -1, 0);
					loc_874_ = rt_and_i32(loc_884_, 3);
					if rt_greater_than_equal_u32(bit32_or(loc_883_ + -2, 0), 3) then
						loc_883_ = loc_865_;
						loc_865_ = loc_883_;
						loc_876_ = bit32_or(loc_883_ + 16, 0);
						loc_871_ = 0;
						loc_873_ = 1;
						loc_875_ = rt_and_i32(loc_884_, -4);
						repeat
							rt_yield_budget = rt_yield_budget - 1
							if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
							loc_882_ = loc_872_;
							loc_872_ = rt_load_f32(loc_866_, loc_876_, 0);
							loc_880_ = rt_load_f32(loc_866_, bit32_or(loc_876_ + -4, 0), 0);
							loc_883_ = rt_load_f32(loc_866_, bit32_or(loc_876_ + -8, 0), 0);
							loc_884_ = rt_load_f32(loc_866_, bit32_or(loc_876_ + -12, 0), 0);
							loc_877_ = (rt_greater_than_f32(loc_884_, loc_882_) and 1 or 0);
							if rt_not_equal_i32(loc_877_, 0) then
								loc_878_ = loc_875_;
								loc_875_ = loc_883_;
								loc_879_ = loc_872_;
								loc_881_ = loc_880_;
								loc_871_, loc_882_ = loc_882_, loc_871_;
								loc_882_, loc_873_ = loc_873_, loc_882_;
								loc_873_, loc_884_ = loc_884_, loc_873_;
							else
								loc_878_ = loc_875_;
								loc_875_ = loc_883_;
								loc_879_ = loc_872_;
								loc_881_ = loc_880_;
								loc_871_, loc_882_ = loc_882_, loc_871_;
								loc_882_, loc_873_ = loc_873_, loc_882_;
								loc_873_, loc_884_ = loc_884_, loc_873_;
								loc_873_ = loc_871_;
							end
							loc_883_ = (rt_greater_than_f32(loc_883_, loc_873_) and 1 or 0);
							if not (rt_not_equal_i32(loc_883_, 0)) then
								loc_875_ = loc_873_;
							end
							loc_881_ = (rt_greater_than_f32(loc_881_, loc_875_) and 1 or 0);
							if not (rt_not_equal_i32(loc_881_, 0)) then
								loc_880_ = loc_875_;
							end
							loc_879_ = (rt_greater_than_f32(loc_879_, loc_880_) and 1 or 0);
							if not (rt_not_equal_i32(loc_879_, 0)) then
								loc_875_ = loc_872_;
								loc_872_ = loc_880_;
							end
							loc_871_ = bit32_or(loc_882_ + 3, 0);
							loc_873_ = bit32_or(loc_882_ + 2, 0);
							loc_880_ = bit32_or(loc_882_ + 1, 0);
							if rt_not_equal_i32(loc_877_, 0) then
								loc_875_ = loc_882_;
								loc_877_ = loc_871_;
							else
								loc_875_ = loc_882_;
								loc_877_ = loc_871_;
								loc_882_ = loc_884_;
							end
							if not (rt_not_equal_i32(loc_883_, 0)) then
								loc_880_ = loc_882_;
							end
							if not (rt_not_equal_i32(loc_881_, 0)) then
								loc_873_ = loc_880_;
							end
							if not (rt_not_equal_i32(loc_879_, 0)) then
								loc_871_ = loc_873_;
							end
							loc_876_ = bit32_or(loc_876_ + 16, 0);
							loc_873_ = bit32_or(loc_875_ + 4, 0);
							loc_875_ = loc_878_;
						until not (rt_not_equal_i32(loc_877_, loc_878_))
					else
						loc_883_ = loc_865_;
						loc_865_ = loc_883_;
						loc_871_ = 0;
						loc_873_ = 1;
					end
					if rt_equal_i32(loc_874_, 0) then
						loc_872_ = 0;
					else
						loc_875_ = loc_873_;
						loc_873_ = loc_865_;
						loc_876_ = loc_874_;
						loc_865_ = loc_873_;
						loc_874_ = loc_872_;
						loc_873_ = bit32_or(loc_873_ + rt_shift_left_i32(loc_875_, 2), 0);
						loc_872_ = loc_875_;
						loc_875_ = loc_876_;
						repeat
							rt_yield_budget = rt_yield_budget - 1
							if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
							loc_876_ = loc_874_;
							loc_874_ = loc_865_;
							loc_874_ = rt_load_f32(loc_866_, loc_873_, 0);
							loc_865_ = (rt_greater_than_f32(loc_874_, loc_876_) and 1 or 0);
							if rt_not_equal_i32(loc_865_, 0) then
								loc_871_, loc_872_ = loc_872_, loc_871_;
								loc_875_, loc_876_ = loc_876_, loc_875_;
							else
								loc_871_, loc_872_ = loc_872_, loc_871_;
								loc_875_, loc_876_ = loc_876_, loc_875_;
								loc_874_ = loc_875_;
							end
							if rt_not_equal_i32(loc_865_, 0) then
								loc_875_ = loc_871_;
							else
								loc_875_ = loc_871_;
								loc_871_ = loc_872_;
							end
							loc_873_ = bit32_or(loc_873_ + 4, 0);
							loc_872_ = bit32_or(loc_875_ + 1, 0);
							loc_876_ = bit32_or(loc_876_ + -1, 0);
							loc_875_ = loc_876_;
						until loc_876_ == 0
						loc_872_ = 0;
					end
				end
			else
				loc_864_ = loc_863_;
				loc_865_ = loc_858_;
				loc_866_ = loc_857_;
				loc_867_ = loc_853_;
				loc_868_ = loc_854_;
				loc_869_ = loc_855_;
				loc_870_ = loc_856_;
				loc_872_ = loc_859_;
				loc_881_ = loc_862_;
				loc_882_ = loc_861_;
				loc_883_ = loc_860_;
				if rt_less_than_s32(loc_872_, 1) then
					loc_871_ = loc_880_;
					loc_880_ = loc_881_;
					loc_881_ = loc_882_;
					loc_882_ = loc_883_;
					loc_883_ = loc_872_;
				else
					loc_871_ = loc_880_;
					loc_880_ = loc_881_;
					loc_881_ = loc_882_;
					loc_882_ = loc_883_;
					loc_883_ = loc_872_;
					loc_885_ = rt_and_i32(loc_883_, 1);
					loc_887_ = bit32_or(loc_883_ + -1, 0);
					if rt_not_equal_i32(loc_887_, 0) then
						loc_877_ = loc_883_;
						loc_883_ = loc_887_;
						loc_887_ = loc_882_;
						loc_882_ = loc_865_;
						loc_878_ = loc_882_;
						loc_879_ = loc_877_;
						loc_886_ = 0;
						loc_877_ = rt_and_i32(loc_877_, 2147483646);
						repeat
							rt_yield_budget = rt_yield_budget - 1
							if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
							loc_875_ = loc_877_;
							loc_877_ = loc_871_;
							loc_877_ = rt_load_f32(loc_866_, loc_882_, 0);
							rt_store_f32(loc_866_, loc_882_, 0, rt_divide_f32(loc_877_, loc_887_))
							loc_871_ = bit32_or(loc_882_ + 4, 0);
							loc_877_ = rt_load_f32(loc_866_, loc_871_, 0);
							rt_store_f32(loc_866_, loc_871_, 0, rt_divide_f32(loc_877_, loc_887_))
							loc_876_ = bit32_or(loc_886_ + 2, 0);
							loc_886_ = loc_876_;
							loc_882_ = bit32_or(loc_882_ + 8, 0);
							loc_877_ = loc_875_;
						until not (rt_not_equal_i32(loc_875_, loc_876_))
					else
						loc_877_ = loc_883_;
						loc_883_ = loc_887_;
						loc_887_ = loc_882_;
						loc_882_ = loc_865_;
						loc_878_ = loc_882_;
						loc_879_ = loc_877_;
						loc_886_ = 0;
					end
					if not (rt_equal_i32(loc_885_, 0)) then
						loc_885_ = bit32_or(loc_878_ + rt_shift_left_i32(loc_886_, 2), 0);
						loc_886_ = rt_load_f32(loc_866_, loc_885_, 0);
						rt_store_f32(loc_866_, loc_885_, 0, rt_divide_f32(loc_886_, loc_887_))
					end
					loc_875_ = rt_load_f32(loc_866_, loc_878_, 0);
					loc_882_ = 1;
					if not (rt_equal_i32(loc_879_, 1)) then
						loc_887_ = loc_882_;
						loc_882_ = rt_and_i32(loc_883_, 3);
						if rt_less_than_u32(bit32_or(loc_879_ + -2, 0), 3) then
							loc_877_ = loc_887_;
						else
							loc_885_ = loc_871_;
							loc_886_ = loc_878_;
							loc_883_, loc_887_ = loc_887_, loc_883_;
							loc_878_ = loc_886_;
							loc_883_ = loc_887_;
							loc_877_ = 0;
							loc_876_ = bit32_or(loc_886_ + 16, 0);
							loc_874_ = rt_and_i32(loc_887_, -4);
							repeat
								rt_yield_budget = rt_yield_budget - 1
								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
								loc_886_ = loc_875_;
								loc_875_ = rt_load_f32(loc_866_, loc_876_, 0);
								loc_887_ = rt_load_f32(loc_866_, bit32_or(loc_876_ + -4, 0), 0);
								loc_871_ = rt_load_f32(loc_866_, bit32_or(loc_876_ + -8, 0), 0);
								loc_885_ = rt_load_f32(loc_866_, bit32_or(loc_876_ + -12, 0), 0);
								if rt_greater_than_f32(loc_885_, loc_886_) then
									loc_865_ = loc_887_;
									loc_872_ = loc_874_;
									loc_873_ = loc_875_;
									loc_874_ = loc_887_;
									loc_887_ = loc_886_;
									loc_886_ = loc_871_;
								else
									loc_865_ = loc_887_;
									loc_872_ = loc_874_;
									loc_873_ = loc_875_;
									loc_874_ = loc_887_;
									loc_887_ = loc_886_;
									loc_886_ = loc_871_;
									loc_885_ = loc_887_;
								end
								if not (rt_greater_than_f32(loc_886_, loc_885_)) then
									loc_871_ = loc_885_;
								end
								if not (rt_greater_than_f32(loc_865_, loc_871_)) then
									loc_874_ = loc_871_;
								end
								if not (rt_greater_than_f32(loc_873_, loc_874_)) then
									loc_875_ = loc_874_;
								end
								loc_873_ = bit32_or(loc_877_ + 4, 0);
								loc_877_ = loc_873_;
								loc_876_ = bit32_or(loc_876_ + 16, 0);
								loc_874_ = loc_872_;
							until not (rt_not_equal_i32(loc_872_, loc_873_))
							loc_871_ = loc_877_;
							loc_877_ = bit32_or(loc_877_ + 1, 0);
						end
						if not (rt_equal_i32(loc_882_, 0)) then
							loc_876_ = loc_878_;
							loc_878_ = loc_876_;
							loc_877_ = bit32_or(loc_876_ + rt_shift_left_i32(loc_877_, 2), 0);
							repeat
								rt_yield_budget = rt_yield_budget - 1
								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
								loc_876_ = loc_875_;
								loc_875_ = rt_load_f32(loc_866_, loc_877_, 0);
								if not (rt_greater_than_f32(loc_875_, loc_876_)) then
									loc_875_ = loc_876_;
								end
								loc_876_ = bit32_or(loc_882_ + -1, 0);
								loc_882_ = loc_876_;
								loc_877_ = bit32_or(loc_877_ + 4, 0);
							until loc_876_ == 0
						end
					end
					loc_877_ = loc_878_;
					loc_876_ = loc_879_;
					loc_882_ = 0 --[[ 0_f32 ]];
					repeat
						rt_yield_budget = rt_yield_budget - 1
						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
						loc_872_ = loc_867_;
						loc_867_ = loc_872_;
						loc_873_ = rt_load_f32(loc_866_, loc_878_, 0);
						loc_874_ = loc_864_;
						loc_874_ = loc_872_[1](rt_subtract_f32(loc_873_, loc_875_), loc_874_)
						rt_store_f32(loc_866_, loc_878_, 0, loc_874_)
						loc_882_ = rt_add_f32(loc_882_, loc_874_);
						loc_874_ = bit32_or(loc_879_ + -1, 0);
						loc_879_ = loc_874_;
						loc_878_ = bit32_or(loc_878_ + 4, 0);
					until loc_874_ == 0
					loc_878_ = rt_and_i32(loc_876_, 1);
					if rt_not_equal_i32(loc_883_, 0) then
						loc_865_ = loc_877_;
						loc_883_ = loc_876_;
						loc_879_ = 0;
						loc_876_ = rt_and_i32(loc_876_, 2147483646);
						repeat
							rt_yield_budget = rt_yield_budget - 1
							if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
							loc_874_ = loc_876_;
							loc_876_ = loc_871_;
							loc_876_ = rt_load_f32(loc_866_, loc_877_, 0);
							rt_store_f32(loc_866_, loc_877_, 0, rt_divide_f32(loc_876_, loc_882_))
							loc_871_ = bit32_or(loc_877_ + 4, 0);
							loc_876_ = rt_load_f32(loc_866_, loc_871_, 0);
							rt_store_f32(loc_866_, loc_871_, 0, rt_divide_f32(loc_876_, loc_882_))
							loc_875_ = bit32_or(loc_879_ + 2, 0);
							loc_879_ = loc_875_;
							loc_877_ = bit32_or(loc_877_ + 8, 0);
							loc_876_ = loc_874_;
						until not (rt_not_equal_i32(loc_874_, loc_875_))
					else
						loc_865_ = loc_877_;
						loc_883_ = loc_876_;
						loc_879_ = 0;
					end
					if not (rt_equal_i32(loc_878_, 0)) then
						loc_878_ = bit32_or(loc_865_ + rt_shift_left_i32(loc_879_, 2), 0);
						loc_879_ = rt_load_f32(loc_866_, loc_878_, 0);
						rt_store_f32(loc_866_, loc_878_, 0, rt_divide_f32(loc_879_, loc_882_))
					end
				end
				loc_882_ = rt_load_i64(loc_866_, loc_880_, 0);
				loc_882_ = rt_exclusive_or_i64(rt_shift_right_u64(loc_882_, 12), loc_882_);
				loc_882_ = rt_exclusive_or_i64(rt_shift_left_i64(loc_882_, 25), loc_882_);
				loc_882_ = rt_exclusive_or_i64(rt_shift_right_u64(loc_882_, 27), loc_882_);
				rt_store_i64(loc_866_, loc_880_, 0, loc_882_)
				loc_882_ = rt_multiply_f32(rt_convert_u32_to_f32(rt_low_shift_right_u64(rt_multiply_i64(loc_882_, into_bits_i64(1332534557, 625341585)), 40)), 5.960464477539063e-8 --[[ 0.000000059604645_f32 ]]);
				if rt_less_than_equal_f32(loc_881_, 0 --[[ 0_f32 ]]) then
					loc_881_ = 0;
				else
					if rt_equal_i32((rt_greater_than_equal_f32(loc_881_, 1e0 --[[ 1_f32 ]]) and 1 or 0), 0) then
						loc_876_ = loc_881_;
						loc_877_ = loc_868_;
						loc_879_ = loc_870_;
						loc_881_ = loc_864_;
						loc_880_ = loc_869_[1](rt_shift_left_i32(loc_883_, 3), loc_881_)
						loc_878_ = -1;
						if rt_less_than_s32(loc_883_, 1) then
							loc_868_ = loc_877_;
							loc_877_[1](loc_880_, 0, 8, 1, loc_881_)
							loc_877_ = 0;
						else
							loc_875_ = loc_871_;
							loc_878_ = rt_divide_f32(rt_subtract_f32(1e0 --[[ 1_f32 ]], loc_876_), rt_convert_s32_to_f32(bit32_or(loc_883_ + -1, 0)));
							loc_875_ = rt_and_i32(loc_883_, 1);
							if rt_not_equal_i32(loc_883_, 1) then
								loc_868_ = loc_877_;
								loc_874_ = loc_865_;
								loc_877_ = loc_876_;
								loc_865_ = loc_874_;
								loc_883_ = rt_and_i32(loc_883_, 2147483646);
								loc_876_ = 0;
								loc_871_ = 0;
								repeat
									rt_yield_budget = rt_yield_budget - 1
									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
									loc_872_ = rt_load_f32(loc_866_, loc_874_, 0);
									if rt_equal_i32((rt_greater_than_equal_f32(loc_872_, loc_878_) and 1 or 0), 0) then
										loc_873_ = loc_871_;
									else
										loc_873_ = loc_871_;
										loc_871_ = loc_872_;
										loc_872_ = bit32_or(loc_880_ + rt_shift_left_i32(loc_876_, 3), 0);
										rt_store_f32(loc_866_, loc_872_, 0, loc_871_)
										rt_store_i32(loc_866_, loc_872_, 4, loc_873_)
										loc_876_ = bit32_or(loc_876_ + 1, 0);
									end
									loc_872_ = rt_load_f32(loc_866_, bit32_or(loc_874_ + 4, 0), 0);
									if not (rt_equal_i32((rt_greater_than_equal_f32(loc_872_, loc_878_) and 1 or 0), 0)) then
										loc_871_ = loc_872_;
										loc_872_ = bit32_or(loc_880_ + rt_shift_left_i32(loc_876_, 3), 0);
										rt_store_f32(loc_866_, loc_872_, 0, loc_871_)
										rt_store_i32(loc_866_, loc_872_, 4, bit32_or(loc_873_ + 1, 0))
										loc_876_ = bit32_or(loc_876_ + 1, 0);
									end
									loc_871_ = bit32_or(loc_873_ + 2, 0);
									loc_874_ = bit32_or(loc_874_ + 8, 0);
									if rt_equal_i32(loc_883_, loc_871_) then
										loc_873_ = 0;
									else
										loc_873_ = 1;
										loc_884_ = 65535;
									end
								until loc_873_ == 0
							else
								loc_868_ = loc_877_;
								loc_874_ = loc_865_;
								loc_877_ = loc_876_;
								loc_865_ = loc_874_;
								loc_876_ = 0;
								loc_871_ = 0;
							end
							if not (rt_equal_i32(loc_875_, 0)) then
								loc_875_ = loc_878_;
								loc_878_ = rt_load_f32(loc_866_, bit32_or(loc_865_ + rt_shift_left_i32(loc_871_, 2), 0), 0);
								if not (rt_equal_i32((rt_greater_than_equal_f32(loc_878_, loc_875_) and 1 or 0), 0)) then
									loc_875_ = loc_878_;
									loc_878_ = bit32_or(loc_880_ + rt_shift_left_i32(loc_876_, 3), 0);
									rt_store_f32(loc_866_, loc_878_, 0, loc_875_)
									rt_store_i32(loc_866_, loc_878_, 4, loc_871_)
									loc_876_ = bit32_or(loc_876_ + 1, 0);
								end
							end
							loc_868_[1](loc_880_, loc_876_, 8, 1, loc_881_)
							loc_878_ = bit32_or(loc_876_ + -1, 0);
							if rt_less_than_s32(loc_876_, 1) then
								loc_877_ = 0;
							else
								loc_875_ = loc_871_;
								loc_876_, loc_877_ = loc_877_, loc_876_;
								loc_874_ = 0 --[[ 0_f32 ]];
								loc_875_ = loc_877_;
								loc_877_ = 0;
								loc_873_ = loc_880_;
								repeat
									rt_yield_budget = rt_yield_budget - 1
									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
									loc_884_ = rt_load_f32(loc_866_, loc_873_, 0);
									loc_874_ = rt_add_f32(loc_874_, loc_884_);
									if rt_greater_than_f32(loc_874_, loc_876_) then
										loc_872_ = 0;
										loc_884_ = 1;
									else
										loc_877_ = bit32_or(loc_877_ + 1, 0);
										loc_873_ = bit32_or(loc_873_ + 8, 0);
										if rt_not_equal_i32(loc_875_, loc_877_) then
											loc_872_ = 1;
											loc_884_ = 65535;
										else
											loc_872_ = 0;
											loc_884_ = 0;
										end
									end
								until loc_872_ == 0
								if not (rt_not_equal_i32(loc_884_, 0)) then
									loc_877_, loc_878_ = loc_878_, loc_877_;
									loc_878_ = loc_877_;
								end
								loc_871_ = buffer_read_i32(loc_866_[1], bit32_or(loc_880_ + rt_shift_left_i32(loc_877_, 3), 0), 4);
								loc_876_ = 0 --[[ 0_f32 ]];
								loc_875_ = bit32_or(loc_877_ + 1, 0);
								loc_877_ = loc_880_;
								loc_874_ = rt_multiply_f32(loc_882_, loc_874_);
								repeat
									rt_yield_budget = rt_yield_budget - 1
									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
									loc_884_ = rt_load_f32(loc_866_, loc_877_, 0);
									loc_876_ = rt_add_f32(loc_876_, loc_884_);
									if rt_less_than_f32(loc_874_, loc_876_) then
										loc_873_ = 0;
										loc_884_ = 0;
									else
										loc_875_ = bit32_or(loc_875_ + -1, 0);
										loc_877_ = bit32_or(loc_877_ + 8, 0);
										if rt_equal_i32(loc_875_, 0) then
											loc_873_ = 0;
											loc_884_ = 1;
										else
											loc_873_ = 1;
											loc_884_ = 65535;
										end
									end
								until loc_873_ == 0
								if rt_not_equal_i32(loc_884_, 0) then
									loc_877_ = 1;
								else
									loc_876_ = loc_871_;
									loc_871_ = buffer_read_i32(loc_866_[1], bit32_or(loc_877_ + 4, 0), 0);
									loc_877_ = 1;
								end
							end
						end
						if not (rt_not_equal_i32(loc_877_, 0)) then
							loc_877_ = loc_871_;
							loc_871_ = buffer_read_i32(loc_866_[1], bit32_or(loc_880_ + rt_shift_left_i32(loc_878_, 3), 0), 4);
						end
						loc_870_ = loc_879_;
						loc_879_[1](loc_880_, loc_881_)
						loc_881_ = 1;
					else
						loc_877_ = loc_868_;
						loc_879_ = loc_870_;
						loc_880_ = loc_864_;
						loc_868_ = loc_877_;
						loc_870_ = loc_879_;
						loc_881_ = 0;
						loc_864_ = loc_880_;
					end
				end
				if rt_not_equal_i32(loc_881_, 0) then
					loc_872_ = 0;
				else
					loc_881_ = 0;
					if rt_less_than_s32(loc_883_, 1) then
						loc_865_, loc_881_ = loc_881_, loc_865_;
						loc_881_, loc_882_ = loc_882_, loc_881_;
						loc_883_, loc_884_ = loc_884_, loc_883_;
					else
						loc_880_ = loc_882_;
						loc_882_ = loc_865_;
						loc_865_ = loc_881_;
						loc_883_, loc_884_ = loc_884_, loc_883_;
						loc_881_ = 0 --[[ 0_f32 ]];
						repeat
							rt_yield_budget = rt_yield_budget - 1
							if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
							loc_883_ = rt_load_f32(loc_866_, loc_882_, 0);
							loc_881_ = rt_add_f32(loc_881_, loc_883_);
							if rt_less_than_f32(loc_880_, loc_881_) then
								loc_879_ = 0;
								loc_883_ = 1;
							else
								loc_882_ = bit32_or(loc_882_ + 4, 0);
								loc_865_ = bit32_or(loc_865_ + 1, 0);
								if rt_not_equal_i32(loc_884_, loc_865_) then
									loc_879_ = 1;
									loc_883_ = 65535;
								else
									loc_879_ = 0;
									loc_883_ = 0;
								end
							end
						until loc_879_ == 0
						if not (rt_not_equal_i32(loc_883_, 0)) then
							loc_883_ = loc_884_;
							loc_884_ = loc_865_;
							loc_884_ = loc_883_;
							loc_865_ = loc_883_;
						end
					end
					loc_884_ = bit32_or(loc_884_ + -1, 0);
					if not (rt_less_than_s32(loc_865_, loc_884_)) then
						loc_883_ = loc_865_;
						loc_865_ = loc_884_;
					end
					loc_872_ = 1;
				end
			end
			if not (rt_not_equal_i32(loc_872_, 0)) then
				loc_865_ = loc_871_;
			end
			return loc_865_, loc_864_
		end), "i32,i32,f32,f32,i32->i32")
	end)(module_locals[36], module_locals[134], module_locals[156], module_locals[159], module_locals[3]);
	do (function() --[[spider:chunk]]
	module_locals[65] = { nil };
	module_locals[65][1] = (function(loc_888_)
		return rt_function_type(--[[fn:cmp_prob]](function(loc_889_, loc_890_, loc_891_)
			local loc_892_, loc_893_, loc_894_, loc_895_, loc_896_
			loc_896_ = rt_load_f32(loc_888_, loc_889_, 0);
			loc_894_ = loc_888_;
			loc_892_ = rt_load_f32(loc_894_, loc_890_, 0);
			loc_893_ = -1;
			loc_895_ = (rt_less_than_f32(loc_896_, loc_892_) and 1 or 0);
			if rt_greater_than_f32(loc_896_, loc_892_) then
				loc_892_ = loc_891_;
			else
				loc_892_ = loc_891_;
				loc_893_ = loc_895_;
			end
			return loc_893_, loc_892_
		end), "i32,i32->i32")
	end)(module_locals[3]);
	module_locals[66] = { nil };
	module_locals[120] = { nil };
	module_locals[126] = { nil };
	module_locals[141] = { nil };
	end)() end --[[/spider:chunk]]
	module_locals[66][1] = (function(loc_897_, loc_898_, loc_899_, loc_900_, loc_901_, loc_902_, loc_903_, loc_904_, loc_905_, loc_906_, loc_907_, loc_908_, loc_909_, loc_910_, loc_911_, loc_912_, loc_913_, loc_914_, loc_915_, loc_916_, loc_917_, loc_918_, loc_919_, loc_920_, loc_921_, loc_922_, loc_923_)
		return rt_function_type(--[[fn:main]](function(loc_924_, loc_925_, loc_926_)
			local loc_927_, loc_928_, loc_929_, loc_930_, loc_931_, loc_932_, loc_933_, loc_934_, loc_935_, loc_936_, loc_937_, loc_938_, loc_939_, loc_940_, loc_941_, loc_942_, loc_943_, loc_944_, loc_945_, loc_946_, loc_947_, loc_948_, loc_949_, loc_950_, loc_951_, loc_952_, loc_953_, loc_954_, loc_955_, loc_956_, loc_957_, loc_958_, loc_959_, loc_960_, loc_961_, loc_962_, loc_963_, loc_964_, loc_965_, loc_966_, loc_967_, loc_968_, loc_969_, loc_970_, loc_971_, loc_972_, loc_973_, loc_974_, loc_975_, loc_976_, loc_977_, loc_978_, loc_979_, loc_980_
			loc_980_ = loc_922_[1];
			loc_929_ = loc_922_;
			loc_980_ = bit32_or(loc_980_ - 1488, 0);
			loc_929_[1] = loc_980_;
			loc_930_ = loc_923_;
			loc_979_ = loc_926_;
			loc_977_ = loc_906_[1](bit32_or(loc_980_ + 412, 0), 1152, loc_979_)
			loc_957_ = 0;
			loc_958_ = 0;
			loc_969_ = 0;
			loc_970_ = 0;
			if rt_equal_i32(loc_977_, 0) then
				loc_928_ = loc_924_;
				loc_932_ = loc_898_;
				loc_933_ = loc_899_;
				loc_934_ = loc_900_;
				loc_935_ = loc_901_;
				loc_936_ = loc_902_;
				loc_937_ = loc_903_;
				loc_938_ = loc_904_;
				loc_939_ = loc_905_;
				loc_940_ = loc_906_;
				loc_941_ = loc_907_;
				loc_942_ = loc_908_;
				loc_943_ = loc_909_;
				loc_944_ = loc_910_;
				loc_945_ = loc_911_;
				loc_946_ = loc_912_;
				loc_947_ = loc_913_;
				loc_948_ = loc_914_;
				loc_949_ = loc_915_;
				loc_950_ = loc_916_;
				loc_951_ = loc_917_;
				loc_952_ = loc_918_;
				loc_953_ = loc_919_;
				loc_975_ = loc_920_;
				loc_976_ = loc_921_;
				loc_978_ = loc_897_;
				loc_972_ = loc_932_[1]()
				loc_977_ = loc_943_[1](bit32_or(loc_980_ + 204, 0), 1167, 2, loc_979_)
				if rt_equal_i32(loc_977_, 0) then
					loc_977_ = rt_load_i64(loc_930_, loc_980_, 204);
					loc_974_ = rt_load_i64(loc_930_, loc_980_, 212);
					loc_971_ = rt_load_i64(loc_930_, loc_980_, 220);
					loc_968_ = buffer_read_i32(loc_930_[1], loc_980_, 228);
					loc_967_ = buffer_read_i32(loc_930_[1], loc_980_, 408);
					loc_973_ = loc_932_[1]()
					rt_store_i32(loc_930_, bit32_or(loc_980_ + 140, 0), 0, loc_967_)
					rt_store_i32(loc_930_, bit32_or(loc_980_ + 136, 0), 0, loc_968_)
					rt_store_i64(loc_930_, bit32_or(loc_980_ + 128, 0), 0, loc_971_)
					rt_store_i32(loc_930_, bit32_or(loc_980_ + 144, 0), 0, bit32_or(loc_973_ - loc_972_, 0))
					rt_store_i64(loc_930_, loc_980_, 120, loc_974_)
					rt_store_i64(loc_930_, loc_980_, 112, loc_977_)
					loc_977_ = loc_950_[1](1719, bit32_or(loc_980_ + 112, 0), loc_979_)
					loc_977_ = loc_933_[1](3)
					if not (rt_equal_i32(loc_977_, 0)) then
						loc_974_ = loc_944_;
						loc_977_ = loc_951_;
						loc_944_ = loc_974_;
						loc_951_ = loc_977_;
						loc_974_[1](3, loc_979_)
						loc_977_ = loc_977_[1](1126, loc_979_)
					end
					loc_977_ = loc_933_[1](5)
					if not (rt_equal_i32(loc_977_, 0)) then
						loc_974_ = loc_945_;
						loc_977_ = loc_951_;
						loc_945_ = loc_974_;
						loc_951_ = loc_977_;
						loc_974_[1](4, 5, loc_979_)
						loc_977_ = loc_977_[1](1102, loc_979_)
					end
					loc_960_ = loc_933_[1](6)
					loc_974_ = 1;
					if rt_greater_than_s32(loc_960_, 1) then
						loc_977_ = loc_960_;
					else
						loc_973_ = loc_960_;
						loc_977_ = loc_960_;
						loc_960_ = loc_974_;
					end
					loc_974_ = 16;
					if not (rt_less_than_s32(loc_960_, 16)) then
						loc_973_ = loc_960_;
						loc_960_ = loc_974_;
					end
					if not (rt_less_than_s32(loc_977_, 2)) then
						loc_977_ = loc_950_;
						loc_950_ = loc_977_;
						rt_store_i32(loc_930_, loc_980_, 96, loc_960_)
						loc_977_ = loc_977_[1](1982, bit32_or(loc_980_ + 96, 0), loc_979_)
					end
					loc_977_ = loc_933_[1](4)
					if not (rt_equal_i32(loc_977_, 0)) then
						loc_974_ = loc_948_;
						loc_977_ = loc_950_;
						loc_948_ = loc_974_;
						loc_950_ = loc_977_;
						loc_974_ = loc_974_[1](bit32_or(loc_980_ + 204, 0), 1068, 6, loc_979_)
						rt_store_i32(loc_930_, loc_980_, 80, loc_974_)
						loc_977_ = loc_977_[1](1874, bit32_or(loc_980_ + 80, 0), loc_979_)
					end
					loc_931_ = loc_978_;
					loc_954_ = loc_975_;
					loc_955_ = loc_976_;
					loc_961_ = loc_975_[1](4096, loc_979_)
					loc_962_ = loc_975_[1](4352, loc_979_)
					loc_977_ = buffer_read_i32(loc_930_[1], loc_980_, 228);
					loc_963_ = loc_975_[1](rt_shift_left_i32(loc_977_, 2), loc_979_)
					rt_store_i64(loc_930_, loc_980_, 192, into_bits_i64(1, 0))
					loc_977_ = buffer_read_i32(loc_930_[1], loc_980_, 224);
					loc_959_ = loc_976_[1](loc_977_, 1, loc_979_)
					loc_978_[1](3, 0, 0, 0)
					loc_956_ = loc_980_;
					loc_964_ = bit32_or(bit32_or(loc_980_ + 32, 0) + 20, 0);
					loc_965_ = bit32_or(bit32_or(loc_980_ + 32, 0) + 16, 0);
					loc_966_ = 0;
					loc_967_ = 0;
					loc_968_ = 0;
					repeat
						rt_yield_budget = rt_yield_budget - 1
						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
						loc_980_ = loc_927_;
						loc_979_ = loc_934_[1]()
						if rt_not_equal_i32(loc_979_, 2) then
							loc_971_ = loc_957_;
							loc_976_ = loc_956_;
							loc_978_ = loc_933_;
							loc_979_ = loc_932_;
						else
							loc_971_ = loc_957_;
							loc_976_ = loc_956_;
							loc_977_ = loc_968_;
							loc_978_ = loc_933_;
							loc_979_ = loc_932_;
							loc_975_ = buffer_read_i32(loc_930_[1], loc_976_, 224);
							loc_968_ = 0;
							if rt_equal_i32(loc_975_, 0) then
								loc_977_ = loc_931_;
							else
								loc_977_ = loc_931_;
								rt_memory_fill(loc_930_, loc_959_, 0, loc_975_)
							end
							loc_931_ = loc_977_;
							loc_977_[1](5, 0, 0, 0)
						end
						loc_977_ = loc_935_[1](loc_961_, 4096)
						if rt_greater_than_s32(loc_977_, 0) then
							rt_store_i32_into_i8(loc_930_, bit32_or(loc_961_ + loc_977_, 0), 0, 0)
							rt_store_i32(loc_930_, loc_976_, 76, 2094)
							rt_store_i32(loc_930_, loc_976_, 72, loc_961_)
							rt_store_i32(loc_930_, loc_976_, 68, 2143)
							loc_977_ = 2343;
							loc_975_ = 2344;
							if rt_greater_than_s32(loc_968_, 0) then
								loc_956_ = loc_976_;
							else
								loc_956_ = loc_976_;
								loc_977_ = loc_975_;
							end
							rt_store_i32(loc_930_, loc_976_, 64, loc_977_)
							loc_977_ = loc_952_[1](loc_962_, 4352, 1077, bit32_or(loc_956_ + 64, 0), loc_980_)
							loc_976_ = loc_953_[1](loc_962_, loc_980_)
							loc_977_ = buffer_read_i32(loc_930_[1], loc_956_, 228);
							loc_927_ = loc_942_[1](bit32_or(loc_956_ + 412, 0), loc_962_, loc_976_, loc_963_, loc_977_, loc_980_)
							if rt_greater_than_s32(loc_927_, 0) then
								loc_977_ = buffer_read_i32(loc_930_[1], loc_956_, 228);
								if not (rt_less_than_s32(bit32_or(bit32_or(loc_968_ + loc_927_, 0) + 1, 0), loc_977_)) then
									loc_977_ = loc_968_;
									loc_976_ = buffer_read_i32(loc_930_[1], loc_956_, 224);
									loc_968_ = 0;
									if rt_equal_i32(loc_976_, 0) then
										loc_977_ = loc_931_;
									else
										loc_977_ = loc_931_;
										rt_memory_fill(loc_930_, loc_959_, 0, loc_976_)
									end
									loc_931_ = loc_977_;
									loc_977_[1](5, 0, 0, 0)
								end
								loc_977_ = rt_and_i32(loc_927_, 3);
								loc_976_ = 0;
								if not (rt_less_than_u32(loc_927_, 4)) then
									loc_974_ = loc_927_;
									loc_975_ = loc_963_;
									loc_976_ = 0;
									loc_927_ = loc_974_;
									loc_974_ = rt_and_i32(loc_974_, 2147483644);
									repeat
										rt_yield_budget = rt_yield_budget - 1
										if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
										loc_972_ = loc_974_;
										loc_974_ = buffer_read_i32(loc_930_[1], loc_975_, 0);
										rt_store_i32_into_i8(loc_930_, bit32_or(loc_959_ + loc_974_, 0), 0, 1)
										loc_974_ = buffer_read_i32(loc_930_[1], bit32_or(loc_975_ + 4, 0), 0);
										rt_store_i32_into_i8(loc_930_, bit32_or(loc_959_ + loc_974_, 0), 0, 1)
										loc_974_ = buffer_read_i32(loc_930_[1], bit32_or(loc_975_ + 8, 0), 0);
										rt_store_i32_into_i8(loc_930_, bit32_or(loc_959_ + loc_974_, 0), 0, 1)
										loc_974_ = buffer_read_i32(loc_930_[1], bit32_or(loc_975_ + 12, 0), 0);
										rt_store_i32_into_i8(loc_930_, bit32_or(loc_959_ + loc_974_, 0), 0, 1)
										loc_975_ = bit32_or(loc_975_ + 16, 0);
										loc_973_ = bit32_or(loc_976_ + 4, 0);
										loc_976_ = loc_973_;
										loc_974_ = loc_972_;
									until not (rt_not_equal_i32(loc_972_, loc_973_))
								end
								if not (rt_equal_i32(loc_977_, 0)) then
									loc_976_, loc_977_ = loc_977_, loc_976_;
									loc_977_ = bit32_or(loc_963_ + rt_shift_left_i32(loc_977_, 2), 0);
									repeat
										rt_yield_budget = rt_yield_budget - 1
										if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
										loc_975_ = buffer_read_i32(loc_930_[1], loc_977_, 0);
										rt_store_i32_into_i8(loc_930_, bit32_or(loc_959_ + loc_975_, 0), 0, 1)
										loc_977_ = bit32_or(loc_977_ + 4, 0);
										loc_975_ = bit32_or(loc_976_ + -1, 0);
										loc_976_ = loc_975_;
									until loc_975_ == 0
								end
								loc_977_ = buffer_read_i32(loc_930_[1], loc_956_, 228);
								if rt_less_than_s32(bit32_or(loc_927_ + 1, 0), loc_977_) then
									loc_932_ = loc_979_;
									loc_933_ = loc_978_;
									loc_973_ = loc_978_[1](0)
									loc_974_ = loc_978_[1](1)
									loc_975_ = loc_978_[1](7)
									loc_976_ = loc_978_[1](2)
									loc_977_ = loc_979_[1]()
									loc_978_ = 0;
									loc_957_ = loc_968_;
									loc_972_ = 0;
									repeat
										rt_yield_budget = rt_yield_budget - 1
										if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
										loc_980_ = loc_971_;
										loc_971_ = loc_958_;
										loc_968_, loc_970_ = loc_970_, loc_968_;
										loc_980_ = loc_979_;
										loc_931_[1](1, loc_978_, loc_927_, loc_957_)
										loc_980_ = bit32_or(loc_927_ - loc_978_, 0);
										if rt_less_than_s32(loc_980_, loc_960_) then
											loc_971_ = loc_960_;
										else
											loc_971_ = loc_960_;
											loc_980_ = loc_971_;
										end
										loc_969_ = loc_947_[1](bit32_or(loc_956_ + 204, 0), bit32_or(loc_963_ + rt_shift_left_i32(loc_978_, 2), 0), loc_980_, loc_957_, loc_979_)
										loc_970_ = loc_934_[1]()
										loc_968_ = bit32_or(loc_980_ + loc_957_, 0);
										loc_972_ = bit32_or(loc_980_ + loc_972_, 0);
										if rt_equal_i32(loc_970_, 1) then
											loc_980_ = 0;
											loc_958_ = 1;
										else
											loc_971_ = loc_957_;
											loc_978_ = bit32_or(loc_980_ + loc_978_, 0);
											if rt_less_than_s32(loc_978_, loc_927_) then
												loc_957_ = loc_968_;
												loc_980_ = 1;
												loc_958_ = 65535;
											else
												loc_957_ = loc_968_;
												loc_980_ = 0;
												loc_958_ = 0;
											end
										end
										loc_971_ = loc_980_;
									until loc_980_ == 0
									if rt_not_equal_i32(loc_958_, 0) then
										loc_957_ = 1694;
									else
										loc_957_ = 2344;
									end
									loc_978_ = loc_932_[1]()
									rt_store_i32(loc_930_, loc_964_, 0, loc_957_)
									rt_store_i32(loc_930_, loc_965_, 0, loc_968_)
									loc_957_ = bit32_or(loc_978_ - loc_977_, 0);
									rt_store_i32(loc_930_, loc_956_, 36, loc_957_)
									rt_store_i32(loc_930_, loc_956_, 32, loc_972_)
									rt_store_f64(loc_930_, loc_956_, 40, rt_divide_f64(rt_convert_s32_to_f64(loc_957_), rt_convert_s32_to_f64(loc_972_)))
									loc_979_ = loc_950_[1](1812, bit32_or(loc_956_ + 32, 0), loc_979_)
									if rt_equal_i32(loc_970_, 1) then
										loc_957_ = 0;
									else
										if rt_not_equal_i32(loc_969_, 0) then
											loc_977_ = loc_966_;
											loc_966_ = loc_972_;
											loc_978_ = loc_971_;
											loc_971_ = loc_957_;
											loc_957_ = loc_974_;
											loc_974_ = loc_950_;
											loc_950_ = loc_975_;
											loc_975_ = loc_931_;
											loc_931_ = loc_976_;
											loc_976_ = loc_967_;
											loc_979_ = loc_927_;
											loc_958_, loc_973_ = loc_973_, loc_958_;
											loc_978_ = buffer_read_i32(loc_930_[1], loc_956_, 224);
											loc_937_[1](loc_969_, loc_978_)
											loc_972_ = loc_932_[1]()
											rt_store_i32(loc_930_, 0, 27328, 0)
											loc_979_ = buffer_read_i32(loc_930_[1], loc_956_, 228);
											loc_967_ = 0;
											if not (rt_greater_than_equal_s32(loc_968_, loc_979_)) then
												loc_979_ = loc_967_;
												loc_979_ = 120;
												if rt_less_than_s32(loc_931_, 1) then
													loc_967_ = loc_931_;
													loc_977_ = loc_950_;
													loc_978_ = loc_957_;
													loc_958_, loc_979_ = loc_979_, loc_958_;
													loc_966_, loc_973_ = loc_973_, loc_966_;
													loc_973_, loc_968_ = loc_968_, loc_973_;
													loc_968_, loc_971_ = loc_971_, loc_968_;
												else
													loc_967_ = loc_931_;
													loc_977_ = loc_950_;
													loc_978_ = loc_957_;
													loc_958_, loc_979_ = loc_979_, loc_958_;
													loc_966_, loc_973_ = loc_973_, loc_966_;
													loc_973_, loc_968_ = loc_968_, loc_973_;
													loc_968_, loc_971_ = loc_971_, loc_968_;
													loc_958_ = loc_967_;
												end
												loc_967_ = 0;
												loc_957_ = rt_divide_f32(rt_convert_s32_to_f32(loc_977_), 1e3 --[[ 1000_f32 ]]);
												loc_950_ = rt_divide_f32(rt_convert_s32_to_f32(loc_978_), 1e3 --[[ 1000_f32 ]]);
												loc_931_ = rt_divide_f32(rt_convert_s32_to_f32(loc_979_), 1e3 --[[ 1000_f32 ]]);
												repeat
													rt_yield_budget = rt_yield_budget - 1
													if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
													loc_979_ = loc_971_;
													loc_971_ = buffer_read_i32(loc_930_[1], loc_956_, 224);
													if rt_equal_i32((rt_greater_than_f32(loc_957_, 1e0 --[[ 1_f32 ]]) and 1 or 0), 0) then
														loc_977_ = loc_966_;
														loc_978_ = loc_968_;
														loc_968_ = loc_969_;
														loc_979_ = loc_976_;
														loc_976_ = loc_970_;
													else
														loc_977_ = loc_966_;
														loc_978_ = loc_968_;
														loc_968_ = loc_969_;
														loc_979_ = loc_976_;
														loc_976_ = loc_970_;
														if not (rt_less_than_s32(loc_971_, 1)) then
															loc_970_ = loc_959_;
															loc_978_ = loc_968_;
															loc_959_ = loc_970_;
															loc_969_ = loc_971_;
															repeat
																rt_yield_budget = rt_yield_budget - 1
																if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																loc_966_ = rt_load_i32_from_u8(loc_930_, loc_970_, 0);
																if not (rt_equal_i32(loc_966_, 0)) then
																	loc_966_ = rt_load_f32(loc_930_, loc_978_, 0);
																	if rt_equal_i32((rt_greater_than_f32(loc_966_, 0 --[[ 0_f32 ]]) and 1 or 0), 0) then
																		loc_927_ = loc_957_;
																		loc_957_ = loc_927_;
																		loc_966_ = rt_multiply_f32(loc_927_, loc_966_);
																	else
																		loc_927_ = loc_957_;
																		loc_957_ = loc_927_;
																		loc_966_ = rt_divide_f32(loc_966_, loc_927_);
																	end
																	rt_store_f32(loc_930_, loc_978_, 0, loc_966_)
																end
																loc_978_ = bit32_or(loc_978_ + 4, 0);
																loc_970_ = bit32_or(loc_970_ + 1, 0);
																loc_966_ = bit32_or(loc_969_ + -1, 0);
																loc_969_ = loc_966_;
															until loc_966_ == 0
														end
													end
													loc_971_ = loc_949_[1](loc_968_, loc_971_, loc_931_, loc_950_, bit32_or(loc_956_ + 192, 0), loc_979_)
													rt_store_i32_into_i8(loc_930_, bit32_or(loc_959_ + loc_971_, 0), 0, 1)
													loc_938_[1](loc_971_, loc_973_)
													if rt_not_equal_i32(rt_and_i32(loc_971_, -5), 3) then
														loc_969_ = loc_941_[1](bit32_or(loc_956_ + 412, 0), loc_971_, bit32_or(loc_956_ + 188, 0), loc_979_)
														loc_979_ = buffer_read_i32(loc_930_[1], 0, 27328);
														loc_978_ = buffer_read_i32(loc_930_[1], loc_956_, 188);
														if not (rt_less_than_s32(bit32_or(loc_979_ + loc_978_, 0), 65)) then
															loc_970_ = loc_939_;
															loc_939_ = loc_970_;
															loc_970_[1](27344, loc_979_)
															loc_979_ = 0;
														end
														if not (rt_equal_i32(loc_978_, 0)) then
															rt_memory_copy(loc_930_, bit32_or(loc_979_ + 27344, 0), loc_930_, loc_969_, loc_978_)
														end
														loc_979_ = bit32_or(loc_979_ + loc_978_, 0);
														rt_store_i32(loc_930_, 0, 27328, loc_979_)
														loc_970_ = 1;
														if rt_less_than_s32(loc_979_, 1) then
															loc_966_ = loc_979_;
														else
															loc_966_ = loc_979_;
															loc_979_ = loc_970_;
														end
														loc_927_ = loc_966_;
														loc_970_ = bit32_or(loc_979_ + -1, 0);
														repeat
															rt_yield_budget = rt_yield_budget - 1
															if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
															loc_979_ = loc_977_;
															if rt_greater_than_s32(loc_927_, 1) then
																loc_977_ = loc_969_;
																loc_979_ = loc_927_;
																loc_978_ = rt_load_i32_from_s8(loc_930_, bit32_or(loc_979_ + 27343, 0), 0);
																loc_969_ = bit32_or(loc_979_ + -1, 0);
																if rt_less_than_s32(loc_978_, -64) then
																	loc_927_ = loc_969_;
																	loc_979_ = 1;
																	loc_977_ = 65535;
																else
																	loc_927_ = loc_969_;
																	loc_979_ = 0;
																	loc_977_ = 1;
																end
															else
																loc_979_ = 0;
																loc_977_ = 0;
															end
														until loc_979_ == 0
														if not (rt_not_equal_i32(loc_977_, 0)) then
															loc_977_ = loc_969_;
															loc_978_ = rt_load_i32_from_u8(loc_930_, bit32_or(loc_970_ + 27344, 0), 0);
															loc_969_ = loc_970_;
														end
														if rt_not_equal_i32(rt_and_i32(loc_978_, 224), 192) then
															loc_978_ = rt_and_i32(loc_978_, 255);
															if rt_not_equal_i32(rt_and_i32(loc_978_, 240), 224) then
																loc_927_ = 4;
																loc_977_ = 1;
																if not (rt_equal_i32(rt_and_i32(loc_978_, 248), 240)) then
																	loc_927_ = loc_977_;
																end
															else
																loc_927_ = 3;
															end
														else
															loc_927_ = 2;
														end
														if not (rt_less_than_s32(bit32_or(loc_966_ - loc_969_, 0), loc_927_)) then
															loc_969_ = loc_966_;
														end
														if not (rt_less_than_s32(loc_969_, 1)) then
															loc_939_[1](27344, loc_969_)
															loc_966_ = buffer_read_i32(loc_930_[1], 0, 27328);
															loc_966_ = bit32_or(loc_966_ - loc_969_, 0);
															if not (rt_equal_i32(loc_966_, 0)) then
																rt_memory_copy(loc_930_, 27344, loc_930_, bit32_or(loc_969_ + 27344, 0), loc_966_)
															end
															rt_store_i32(loc_930_, 0, 27328, loc_966_)
														end
														loc_967_ = bit32_or(loc_967_ + 1, 0);
														loc_966_ = loc_932_[1]()
														loc_975_[1](2, loc_967_, loc_973_, bit32_or(loc_966_ - loc_972_, 0))
														loc_966_ = loc_934_[1]()
														if rt_not_equal_i32(loc_966_, 1) then
															loc_969_ = loc_946_[1](bit32_or(loc_956_ + 204, 0), loc_971_, loc_973_, loc_976_)
															loc_966_ = buffer_read_i32(loc_930_[1], loc_956_, 228);
															loc_968_ = bit32_or(loc_973_ + 1, 0);
															if rt_greater_than_equal_s32(loc_968_, loc_966_) then
																loc_927_ = 0;
																loc_966_ = 3;
															else
																if rt_less_than_s32(loc_967_, loc_958_) then
																	loc_973_ = loc_968_;
																	loc_927_ = 1;
																	loc_966_ = 65535;
																else
																	loc_973_ = loc_968_;
																	loc_927_ = 0;
																	loc_966_ = 2;
																end
															end
														else
															loc_968_, loc_969_ = loc_969_, loc_968_;
															loc_927_ = 0;
															loc_966_ = 1;
														end
													else
														loc_970_ = loc_977_;
														loc_977_ = loc_978_;
														loc_978_ = loc_968_;
														loc_927_ = 0;
														loc_966_ = 0;
														loc_968_ = loc_977_;
														loc_969_ = loc_978_;
														loc_970_ = loc_976_;
														loc_976_ = loc_979_;
													end
												until loc_927_ == 0
												if (loc_966_) >= 0 and (loc_966_) < 3 then
													if (loc_966_) < 1 then
														loc_966_ = loc_968_;
														loc_968_ = loc_946_;
														loc_946_ = loc_968_;
														loc_971_ = loc_968_[1](bit32_or(loc_956_ + 204, 0), loc_971_, loc_973_, loc_976_)
														loc_968_ = bit32_or(loc_973_ + 1, 0);
													elseif (loc_966_) > 1 then
													else
														loc_968_, loc_971_ = loc_971_, loc_968_;
														loc_968_ = loc_973_;
													end
												else
												end
												loc_973_ = buffer_read_i32(loc_930_[1], 0, 27328);
												if not (rt_less_than_s32(loc_973_, 1)) then
													loc_971_ = loc_939_;
													loc_939_ = loc_971_;
													loc_971_[1](27344, loc_973_)
													rt_store_i32(loc_930_, 0, 27328, 0)
												end
											end
											loc_973_ = loc_932_[1]()
											loc_966_ = bit32_or(loc_973_ - loc_972_, 0);
											loc_973_ = 0;
											if not (rt_less_than_s32(loc_967_, 1)) then
												if not (rt_less_than_s32(loc_966_, 1)) then
													loc_971_ = loc_973_;
													loc_972_ = loc_966_;
													loc_973_ = loc_967_;
													loc_966_ = loc_972_;
													loc_967_ = loc_973_;
													loc_973_ = rt_divide_f64(rt_multiply_f64(rt_convert_u32_to_f64(loc_973_), 1e3), rt_convert_u32_to_f64(loc_972_));
												end
											end
											loc_931_ = loc_975_;
											loc_950_ = loc_974_;
											rt_store_i32(loc_930_, bit32_or(loc_956_ + 16, 0), 0, loc_968_)
											loc_972_ = buffer_read_i32(loc_930_[1], loc_956_, 228);
											rt_store_i32(loc_930_, bit32_or(loc_956_ + 20, 0), 0, loc_972_)
											rt_store_i32(loc_930_, loc_956_, 0, loc_967_)
											rt_store_i32(loc_930_, loc_956_, 4, loc_966_)
											rt_store_f64(loc_930_, loc_956_, 8, loc_973_)
											loc_974_ = loc_974_[1](1920, loc_956_, loc_976_)
											loc_975_[1](3, loc_967_, loc_968_, loc_966_)
											loc_957_ = 1;
											loc_971_ = 1;
											loc_958_ = 65535;
										else
											loc_977_ = loc_966_;
											loc_966_ = loc_974_;
											loc_974_ = loc_950_;
											loc_978_ = loc_971_;
											loc_971_ = loc_972_;
											loc_972_ = loc_957_;
											loc_957_ = loc_976_;
											loc_976_ = loc_967_;
											loc_967_ = loc_973_;
											loc_973_ = loc_958_;
											loc_958_ = loc_975_;
											loc_975_ = loc_931_;
											loc_979_ = loc_927_;
											loc_931_ = loc_975_;
											loc_950_ = loc_974_;
											loc_957_ = 0;
											loc_971_ = loc_978_;
											loc_958_ = loc_973_;
											loc_966_ = loc_977_;
											loc_967_ = loc_976_;
											loc_927_ = loc_979_;
										end
									end
									if not (rt_not_equal_i32(loc_957_, 0)) then
										loc_957_ = loc_958_;
										loc_958_ = loc_931_;
										loc_931_ = loc_958_;
										loc_971_ = loc_927_;
										loc_958_[1](3, 0, loc_968_, 0)
										loc_971_ = 1;
										loc_958_ = 65535;
									end
								else
									loc_975_ = loc_958_;
									loc_976_ = loc_971_;
									loc_977_ = loc_979_;
									loc_979_ = loc_931_;
									loc_931_ = loc_979_;
									loc_932_ = loc_977_;
									loc_933_ = loc_978_;
									loc_979_[1](4, 201, loc_927_, 0)
									loc_971_ = 1;
									loc_958_ = 65535;
								end
							else
								loc_974_ = loc_927_;
								loc_975_ = loc_958_;
								loc_976_ = loc_971_;
								loc_977_ = loc_979_;
								loc_979_ = loc_931_;
								loc_931_ = loc_979_;
								loc_932_ = loc_977_;
								loc_933_ = loc_978_;
								loc_979_[1](4, 200, 0, 0)
								loc_971_ = 1;
								loc_958_ = 65535;
							end
						else
							loc_972_ = loc_977_;
							loc_973_ = loc_958_;
							loc_974_ = loc_971_;
							loc_975_ = loc_979_;
							loc_977_ = loc_978_;
							loc_978_ = loc_931_;
							loc_979_ = loc_936_;
							loc_931_ = loc_978_;
							loc_932_ = loc_975_;
							loc_933_ = loc_977_;
							loc_936_ = loc_979_;
							loc_978_[1](3, loc_967_, loc_968_, loc_966_)
							loc_979_[1]()
							loc_971_ = 1;
							loc_958_ = 65535;
							loc_956_ = loc_976_;
						end
						loc_957_ = loc_971_;
					until loc_971_ == 0
					loc_957_ = 1;
				else
					loc_971_ = loc_972_;
					loc_972_ = loc_958_;
					loc_973_ = loc_957_;
					loc_974_ = loc_975_;
					loc_975_ = loc_976_;
					loc_976_ = loc_950_;
					loc_969_, loc_970_ = loc_970_, loc_969_;
					loc_931_ = loc_978_;
					loc_950_ = loc_976_;
					loc_954_ = loc_974_;
					loc_955_ = loc_975_;
					rt_store_i32(loc_930_, loc_980_, 160, loc_977_)
					loc_976_ = loc_976_[1](2042, bit32_or(loc_980_ + 160, 0), loc_979_)
					loc_978_[1](4, loc_977_, 0, 0)
					loc_957_ = 0;
					loc_956_ = loc_980_;
				end
			else
				loc_928_ = loc_924_;
				loc_932_ = loc_898_;
				loc_933_ = loc_899_;
				loc_934_ = loc_900_;
				loc_935_ = loc_901_;
				loc_936_ = loc_902_;
				loc_937_ = loc_903_;
				loc_938_ = loc_904_;
				loc_939_ = loc_905_;
				loc_940_ = loc_906_;
				loc_941_ = loc_907_;
				loc_942_ = loc_908_;
				loc_943_ = loc_909_;
				loc_944_ = loc_910_;
				loc_945_ = loc_911_;
				loc_946_ = loc_912_;
				loc_947_ = loc_913_;
				loc_948_ = loc_914_;
				loc_949_ = loc_915_;
				loc_951_ = loc_917_;
				loc_952_ = loc_918_;
				loc_953_ = loc_919_;
				loc_971_ = loc_969_;
				loc_972_ = loc_958_;
				loc_973_ = loc_957_;
				loc_974_ = loc_920_;
				loc_975_ = loc_921_;
				loc_976_ = loc_916_;
				loc_978_ = loc_897_;
				loc_931_ = loc_978_;
				loc_950_ = loc_976_;
				loc_954_ = loc_974_;
				loc_955_ = loc_975_;
				rt_store_i32(loc_930_, loc_980_, 176, loc_977_)
				loc_976_ = loc_976_[1](2008, bit32_or(loc_980_ + 176, 0), loc_979_)
				loc_978_[1](4, bit32_or(loc_977_ + 100, 0), 0, 0)
				loc_957_ = 0;
				loc_956_ = loc_980_;
			end
			if not (rt_not_equal_i32(loc_957_, 0)) then
				loc_929_[1] = bit32_or(loc_956_ + 1488, 0);
				loc_928_ = 1;
			end
			return loc_928_, loc_927_
		end), "i32,i32->i32")
	end)(module_locals[5], module_locals[6], module_locals[7], module_locals[8], module_locals[9], module_locals[10], module_locals[11], module_locals[12], module_locals[13], module_locals[40], module_locals[41], module_locals[42], module_locals[44], module_locals[47], module_locals[48], module_locals[49], module_locals[60], module_locals[62], module_locals[64], module_locals[120], module_locals[126], module_locals[127], module_locals[141], module_locals[156], module_locals[161], module_locals[164], module_locals[3]);
	do (function() --[[spider:chunk]]
	module_locals[67] = { nil };
	module_locals[67][1] = (function(loc_981_)
		return rt_function_type(--[[fn:progress]](function(loc_982_, loc_983_, loc_984_)
			local loc_985_
			loc_985_ = loc_984_;
			loc_981_[1](0, rt_shift_right_s32(loc_982_, 10), rt_shift_right_s32(loc_983_, 10), 0)
			return loc_985_
		end), "i32,i32->")
	end)(module_locals[5]);
	module_locals[68] = { nil };
	module_locals[68][1] = (function(loc_986_)
		return rt_function_type(--[[fn:kprof_cb]](function(loc_987_, loc_988_, loc_989_)
			local loc_990_
			loc_990_ = loc_989_;
			loc_986_[1](loc_987_, loc_988_)
			return loc_990_
		end), "i32,i32->")
	end)(module_locals[14]);
	module_locals[69] = { nil };
	module_locals[69][1] = (function(loc_991_)
		return rt_function_type(--[[fn:host_matmul]](function(loc_992_, loc_993_, loc_994_, loc_995_, loc_996_, loc_997_, loc_998_, loc_999_, loc_1000_, loc_1001_)
			local loc_1002_, loc_1003_
			loc_1003_ = loc_1001_;
			loc_1003_ = loc_991_[1](loc_992_, loc_993_, loc_994_, loc_995_, loc_996_, loc_997_, loc_998_, loc_999_, loc_1000_)
			return loc_1003_, loc_1002_
		end), "i32,i32,i32,i32,i32,i32,i32,i32,i32->i32")
	end)(module_locals[15]);
	module_locals[70] = { nil };
	module_locals[70][1] = (function(loc_1004_)
		return rt_function_type(--[[fn:host_attention]](function(loc_1005_, loc_1006_, loc_1007_, loc_1008_, loc_1009_, loc_1010_, loc_1011_, loc_1012_, loc_1013_, loc_1014_, loc_1015_, loc_1016_, loc_1017_)
			local loc_1018_, loc_1019_
			loc_1019_ = loc_1017_;
			loc_1019_ = loc_1004_[1](loc_1005_, loc_1006_, loc_1007_, loc_1008_, loc_1009_, loc_1010_, loc_1011_, loc_1012_, loc_1013_, loc_1014_, loc_1015_, loc_1016_)
			return loc_1019_, loc_1018_
		end), "i32,i32,i32,i32,i32,i32,i32,i32,i32,i32,i32,i32->i32")
	end)(module_locals[16]);
	module_locals[71] = { nil };
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[71][1] = (function(loc_1020_, loc_1021_, loc_1022_)
		return rt_function_type(--[[fn:selftest_report]](function(loc_1023_, loc_1024_, loc_1025_, loc_1026_, loc_1027_)
			local loc_1028_, loc_1029_, loc_1030_, loc_1031_, loc_1032_, loc_1033_, loc_1034_, loc_1035_, loc_1036_
			loc_1036_ = loc_1021_[1];
			loc_1029_ = loc_1021_;
			loc_1031_ = bit32_or(loc_1036_ - 32, 0);
			loc_1029_[1] = loc_1031_;
			if rt_equal_i32(loc_1024_, 0) then
				loc_1028_ = loc_1020_;
				loc_1030_ = loc_1022_;
				loc_1033_ = loc_1027_;
				loc_1034_ = loc_1023_;
				loc_1035_ = loc_1025_;
				loc_1036_ = loc_1026_;
				loc_1032_ = loc_1028_;
				rt_store_i32(loc_1030_, loc_1031_, 8, loc_1036_)
				rt_store_i32(loc_1030_, loc_1031_, 4, loc_1035_)
				rt_store_i32(loc_1030_, loc_1031_, 0, loc_1034_)
				loc_1033_ = loc_1028_[1](2288, loc_1031_, loc_1033_)
			else
				loc_1028_ = loc_1020_;
				loc_1030_ = loc_1022_;
				loc_1033_ = loc_1027_;
				loc_1034_ = loc_1023_;
				loc_1035_ = loc_1026_;
				loc_1036_ = loc_1025_;
				loc_1032_ = loc_1028_;
				rt_store_i32(loc_1030_, loc_1031_, 16, loc_1034_)
				loc_1036_ = loc_1033_;
				loc_1036_ = loc_1028_[1](2072, bit32_or(loc_1031_ + 16, 0), loc_1036_)
			end
			loc_1029_[1] = bit32_or(loc_1031_ + 32, 0);
			return loc_1028_
		end), "i32,i32,i32,i32->")
	end)(module_locals[120], module_locals[164], module_locals[3]);
	module_locals[72] = { nil };
	module_locals[72][1] = (function(loc_1037_)
		return rt_function_type(--[[fn:_Exit]](function(loc_1038_, loc_1039_)
			local loc_1040_, loc_1041_
			loc_1041_ = loc_1039_;
			loc_1037_[1](loc_1038_, loc_1041_)
			loc_1041_ = error('unreachable code');
			return loc_1040_
		end), "i32->")
	end)(module_locals[85]);
	module_locals[74] = { nil };
	module_locals[75] = { nil };
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[73][1] = (function(loc_1042_, loc_1043_, loc_1044_, loc_1045_, loc_1046_, loc_1047_, loc_1048_, loc_1049_, loc_1050_)
		return rt_function_type(--[[fn:__main_void]](function(loc_1051_)
			local loc_1052_, loc_1053_, loc_1054_, loc_1055_, loc_1056_, loc_1057_, loc_1058_, loc_1059_, loc_1060_, loc_1061_, loc_1062_, loc_1063_, loc_1064_, loc_1065_, loc_1066_
			loc_1066_ = loc_1049_[1];
			loc_1054_ = loc_1049_;
			loc_1053_ = bit32_or(loc_1066_ - 16, 0);
			loc_1054_[1] = loc_1053_;
			loc_1055_ = loc_1050_;
			loc_1066_ = loc_1051_;
			loc_1066_ = loc_1045_[1](bit32_or(loc_1053_ + 8, 0), bit32_or(loc_1053_ + 12, 0), loc_1066_)
			if rt_not_equal_i32(loc_1066_, 0) then
				loc_1052_ = loc_1043_;
				loc_1056_ = loc_1042_;
				loc_1058_ = loc_1044_;
				loc_1059_ = loc_1045_;
				loc_1060_ = loc_1046_;
				loc_1061_ = loc_1047_;
				loc_1062_ = loc_1048_;
				loc_1057_ = loc_1052_;
				loc_1052_[1](71, loc_1063_)
				loc_1063_ = error('unreachable code');
			else
				loc_1052_ = loc_1043_;
				loc_1056_ = loc_1042_;
				loc_1058_ = loc_1044_;
				loc_1059_ = loc_1045_;
				loc_1060_ = loc_1046_;
				loc_1061_ = loc_1047_;
				loc_1062_ = loc_1048_;
				loc_1066_ = buffer_read_i32(loc_1055_[1], loc_1053_, 8);
				loc_1057_ = bit32_or(loc_1066_ + 1, 0);
				if rt_equal_i32(loc_1057_, 0) then
					loc_1057_ = loc_1052_;
					loc_1052_[1](70, loc_1063_)
					loc_1063_ = error('unreachable code');
				else
					loc_1065_ = buffer_read_i32(loc_1055_[1], loc_1053_, 12);
					loc_1066_ = loc_1063_;
					loc_1064_ = loc_1060_[1](loc_1065_, loc_1066_)
					if rt_equal_i32(loc_1064_, 0) then
						loc_1057_ = loc_1052_;
						loc_1052_[1](70, loc_1063_)
						loc_1063_ = error('unreachable code');
					else
						loc_1066_ = loc_1063_;
						loc_1065_ = loc_1062_[1](loc_1057_, 4, loc_1066_)
						if rt_equal_i32(loc_1065_, 0) then
							loc_1063_ = loc_1052_;
							loc_1052_ = loc_1064_;
							loc_1064_ = loc_1066_;
							loc_1061_, loc_1065_ = loc_1065_, loc_1061_;
							loc_1057_ = loc_1063_;
							loc_1061_ = loc_1065_;
							loc_1065_[1](loc_1052_, loc_1064_)
							loc_1063_[1](70, loc_1064_)
							loc_1064_ = error('unreachable code');
						else
							loc_1063_ = loc_1052_;
							loc_1052_ = loc_1064_;
							loc_1064_ = loc_1066_;
							loc_1061_, loc_1065_ = loc_1065_, loc_1061_;
							loc_1066_ = loc_1064_;
							loc_1064_ = loc_1058_[1](loc_1061_, loc_1052_, loc_1066_)
							if rt_not_equal_i32(loc_1064_, 0) then
								loc_1064_ = loc_1063_;
								loc_1063_ = loc_1061_;
								loc_1052_, loc_1065_ = loc_1065_, loc_1052_;
								loc_1065_, loc_1066_ = loc_1066_, loc_1065_;
								loc_1057_ = loc_1064_;
								loc_1061_ = loc_1052_;
								loc_1052_[1](loc_1066_, loc_1065_)
								loc_1052_[1](loc_1063_, loc_1065_)
								loc_1064_[1](71, loc_1065_)
								loc_1065_ = error('unreachable code');
							else
								loc_1064_ = loc_1063_;
								loc_1063_ = loc_1061_;
								loc_1061_ = loc_1052_;
								loc_1052_ = loc_1065_;
								loc_1065_ = loc_1066_;
								loc_1066_ = loc_1053_;
								loc_1053_ = loc_1056_;
								loc_1056_ = loc_1053_;
								loc_1057_ = loc_1064_;
								loc_1061_ = loc_1052_;
								loc_1064_ = buffer_read_i32(loc_1055_[1], loc_1066_, 8);
								loc_1053_ = loc_1053_[1](loc_1064_, loc_1063_, loc_1065_)
								loc_1054_[1] = bit32_or(loc_1066_ + 16, 0);
							end
						end
					end
				end
			end
			return loc_1053_, loc_1052_
		end), "->i32")
	end)(module_locals[66], module_locals[72], module_locals[74], module_locals[75], module_locals[156], module_locals[159], module_locals[161], module_locals[164], module_locals[3]);
	module_locals[74][1] = (function(loc_1067_)
		return rt_function_type(--[[fn:__wasi_args_get]](function(loc_1068_, loc_1069_, loc_1070_)
			local loc_1071_, loc_1072_
			loc_1072_ = loc_1070_;
			loc_1072_ = loc_1067_[1](loc_1068_, loc_1069_)
			return rt_and_i32(loc_1072_, 65535), loc_1071_
		end), "i32,i32->i32")
	end)(module_locals[17]);
	module_locals[75][1] = (function(loc_1073_)
		return rt_function_type(--[[fn:__wasi_args_sizes_get]](function(loc_1074_, loc_1075_, loc_1076_)
			local loc_1077_, loc_1078_
			loc_1078_ = loc_1076_;
			loc_1078_ = loc_1073_[1](loc_1074_, loc_1075_)
			return rt_and_i32(loc_1078_, 65535), loc_1077_
		end), "i32,i32->i32")
	end)(module_locals[18]);
	module_locals[76] = { nil };
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[76][1] = (function(loc_1079_)
		return rt_function_type(--[[fn:__wasi_fd_close]](function(loc_1080_, loc_1081_)
			local loc_1082_, loc_1083_
			loc_1083_ = loc_1081_;
			loc_1083_ = loc_1079_[1](loc_1080_)
			return rt_and_i32(loc_1083_, 65535), loc_1082_
		end), "i32->i32")
	end)(module_locals[19]);
	module_locals[77] = { nil };
	module_locals[77][1] = (function(loc_1084_)
		return rt_function_type(--[[fn:__wasi_fd_fdstat_get]](function(loc_1085_, loc_1086_, loc_1087_)
			local loc_1088_, loc_1089_
			loc_1089_ = loc_1087_;
			loc_1089_ = loc_1084_[1](loc_1085_, loc_1086_)
			return rt_and_i32(loc_1089_, 65535), loc_1088_
		end), "i32,i32->i32")
	end)(module_locals[20]);
	module_locals[78] = { nil };
	module_locals[78][1] = (function(loc_1090_)
		return rt_function_type(--[[fn:__wasi_fd_fdstat_set_flags]](function(loc_1091_, loc_1092_, loc_1093_)
			local loc_1094_, loc_1095_
			loc_1095_ = loc_1093_;
			loc_1095_ = loc_1090_[1](loc_1091_, loc_1092_)
			return rt_and_i32(loc_1095_, 65535), loc_1094_
		end), "i32,i32->i32")
	end)(module_locals[21]);
	module_locals[79] = { nil };
	module_locals[79][1] = (function(loc_1096_)
		return rt_function_type(--[[fn:__wasi_fd_prestat_get]](function(loc_1097_, loc_1098_, loc_1099_)
			local loc_1100_, loc_1101_
			loc_1101_ = loc_1099_;
			loc_1101_ = loc_1096_[1](loc_1097_, loc_1098_)
			return rt_and_i32(loc_1101_, 65535), loc_1100_
		end), "i32,i32->i32")
	end)(module_locals[22]);
	module_locals[80] = { nil };
	module_locals[80][1] = (function(loc_1102_)
		return rt_function_type(--[[fn:__wasi_fd_prestat_dir_name]](function(loc_1103_, loc_1104_, loc_1105_, loc_1106_)
			local loc_1107_, loc_1108_
			loc_1108_ = loc_1106_;
			loc_1108_ = loc_1102_[1](loc_1103_, loc_1104_, loc_1105_)
			return rt_and_i32(loc_1108_, 65535), loc_1107_
		end), "i32,i32,i32->i32")
	end)(module_locals[23]);
	module_locals[81] = { nil };
	module_locals[81][1] = (function(loc_1109_)
		return rt_function_type(--[[fn:__wasi_fd_read]](function(loc_1110_, loc_1111_, loc_1112_, loc_1113_, loc_1114_)
			local loc_1115_, loc_1116_
			loc_1116_ = loc_1114_;
			loc_1116_ = loc_1109_[1](loc_1110_, loc_1111_, loc_1112_, loc_1113_)
			return rt_and_i32(loc_1116_, 65535), loc_1115_
		end), "i32,i32,i32,i32->i32")
	end)(module_locals[24]);
	module_locals[82] = { nil };
	module_locals[82][1] = (function(loc_1117_)
		return rt_function_type(--[[fn:__wasi_fd_seek]](function(loc_1118_, loc_1119_, loc_1120_, loc_1121_, loc_1122_)
			local loc_1123_, loc_1124_
			loc_1124_ = loc_1122_;
			loc_1124_ = loc_1117_[1](loc_1118_, loc_1119_, loc_1120_, loc_1121_)
			return rt_and_i32(loc_1124_, 65535), loc_1123_
		end), "i32,i64,i32,i32->i32")
	end)(module_locals[25]);
	module_locals[83] = { nil };
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[83][1] = (function(loc_1125_)
		return rt_function_type(--[[fn:__wasi_fd_write]](function(loc_1126_, loc_1127_, loc_1128_, loc_1129_, loc_1130_)
			local loc_1131_, loc_1132_
			loc_1132_ = loc_1130_;
			loc_1132_ = loc_1125_[1](loc_1126_, loc_1127_, loc_1128_, loc_1129_)
			return rt_and_i32(loc_1132_, 65535), loc_1131_
		end), "i32,i32,i32,i32->i32")
	end)(module_locals[26]);
	module_locals[84] = { nil };
	module_locals[84][1] = (function(loc_1133_, loc_1134_)
		return rt_function_type(--[[fn:__wasi_path_open]](function(loc_1135_, loc_1136_, loc_1137_, loc_1138_, loc_1139_, loc_1140_, loc_1141_, loc_1142_, loc_1143_)
			local loc_1144_, loc_1145_
			loc_1145_ = loc_1143_;
			loc_1144_ = loc_1134_[1](loc_1137_, loc_1145_)
			loc_1145_ = loc_1133_[1](loc_1135_, loc_1136_, loc_1137_, loc_1144_, loc_1138_, loc_1139_, loc_1140_, loc_1141_, loc_1142_)
			return rt_and_i32(loc_1145_, 65535), loc_1144_
		end), "i32,i32,i32,i32,i64,i64,i32,i32->i32")
	end)(module_locals[27], module_locals[141]);
	module_locals[85][1] = (function(loc_1146_)
		return rt_function_type(--[[fn:__wasi_proc_exit]](function(loc_1147_, loc_1148_)
			local loc_1149_, loc_1150_
			loc_1150_ = loc_1148_;
			loc_1146_[1](loc_1147_)
			loc_1150_ = error('unreachable code');
			return loc_1149_
		end), "i32->")
	end)(module_locals[28]);
	module_locals[86][1] = (function(loc_1151_, loc_1152_)
		return rt_function_type(--[[fn:__wasi_init_tp]](function(loc_1153_)
			local loc_1154_, loc_1155_, loc_1156_, loc_1157_, loc_1158_, loc_1159_, loc_1160_
			rt_store_i32(loc_1152_, 0, 27412, 27412)
			loc_1156_ = loc_1152_;
			loc_1160_ = 1077712;
			if rt_equal_i32(1077712, 0) then
				loc_1154_ = loc_1153_;
				loc_1155_ = loc_1151_;
				loc_1160_ = loc_1155_[1];
				loc_1160_ = (rt_greater_than_u32(loc_1160_, 1024) and 1 or 0);
				loc_1157_ = bit32_or(1077712 - 29132, 0);
				loc_1159_ = 1024;
				if not (rt_not_equal_i32(loc_1160_, 0)) then
					loc_1158_ = loc_1157_;
					loc_1157_ = loc_1159_;
				end
				loc_1159_ = 1077712;
				loc_1158_ = 1024;
				if not (rt_not_equal_i32(loc_1160_, 0)) then
					loc_1159_ = loc_1158_;
				end
			else
				loc_1154_ = loc_1153_;
				loc_1155_ = loc_1151_;
				loc_1159_ = loc_1160_;
				loc_1157_ = bit32_or(1077712 - 29136, 0);
			end
			rt_store_i32(loc_1156_, 56, 27412, 0)
			rt_store_i32(loc_1156_, 52, 27412, loc_1157_)
			rt_store_i32(loc_1156_, 48, 27412, loc_1159_)
			rt_store_i32(loc_1156_, 8, 27412, 27412)
			rt_store_i32(loc_1156_, 4, 27412, 27412)
			loc_1159_ = buffer_read_i32(loc_1156_[1], 0, 27408);
			rt_store_i32(loc_1156_, 12, 27412, loc_1159_)
			loc_1158_ = 0;
			loc_1159_ = 8388608;
			if not (rt_less_than_u32(loc_1157_, 8388608)) then
				loc_1157_ = loc_1159_;
			end
			rt_store_i32(loc_1156_, loc_1158_, 10672, loc_1157_)
			return loc_1154_
		end), "->")
	end)(module_locals[164], module_locals[3]);
	module_locals[87] = { nil };
	module_locals[87][1] = rt_function_type(--[[fn:dummy]](function(loc_1161_)
		local loc_1162_
		loc_1162_ = loc_1161_;
		return loc_1162_
	end), "->");
	module_locals[112] = { nil };
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[88][1] = (function(loc_1163_, loc_1164_)
		return rt_function_type(--[[fn:__wasm_call_dtors]](function(loc_1165_)
			local loc_1166_
			loc_1166_ = loc_1165_;
			loc_1163_[1](loc_1166_)
			loc_1164_[1](loc_1166_)
			return loc_1166_
		end), "->")
	end)(module_locals[87], module_locals[112]);
	module_locals[89] = { nil };
	module_locals[89][1] = rt_function_type(--[[fn:dummy]](function(loc_1167_, loc_1168_)
		local loc_1169_
		loc_1169_ = loc_1168_;
		return loc_1169_
	end), "i32->");
	module_locals[91] = { nil };
	module_locals[117] = { nil };
	module_locals[118] = { nil };
	module_locals[90][1] = (function(loc_1170_, loc_1171_, loc_1172_, loc_1173_, loc_1174_, loc_1175_, loc_1176_)
		return rt_function_type(--[[fn:fclose]](function(loc_1177_, loc_1178_)
			local loc_1179_, loc_1180_, loc_1181_, loc_1182_, loc_1183_, loc_1184_, loc_1185_, loc_1186_, loc_1187_, loc_1188_, loc_1189_, loc_1190_, loc_1191_, loc_1192_
			loc_1182_ = loc_1175_;
			loc_1183_ = loc_1176_;
			loc_1192_ = loc_1178_;
			loc_1181_ = loc_1171_[1](loc_1177_, loc_1192_)
			loc_1191_ = buffer_read_i32(loc_1183_[1], loc_1177_, 12);
			loc_1191_ = rt_table_get_function(loc_1182_, loc_1191_, "i32->i32");
			loc_1180_ = loc_1191_(loc_1177_, loc_1192_)
			loc_1192_ = rt_load_i32_from_u8(loc_1183_, loc_1177_, 0);
			if rt_not_equal_i32(rt_and_i32(loc_1192_, 1), 0) then
				loc_1184_ = loc_1170_;
				loc_1185_ = loc_1171_;
				loc_1186_ = loc_1172_;
				loc_1187_ = loc_1173_;
				loc_1188_ = loc_1174_;
				loc_1189_ = loc_1177_;
			else
				loc_1184_ = loc_1170_;
				loc_1185_ = loc_1171_;
				loc_1186_ = loc_1172_;
				loc_1187_ = loc_1173_;
				loc_1188_ = loc_1174_;
				loc_1189_ = loc_1177_;
				loc_1192_ = loc_1179_;
				loc_1184_[1](loc_1189_, loc_1192_)
				loc_1179_ = loc_1186_[1](loc_1192_)
				loc_1190_ = buffer_read_i32(loc_1183_[1], loc_1189_, 52);
				loc_1192_ = buffer_read_i32(loc_1183_[1], loc_1189_, 48);
				if rt_equal_i32(loc_1192_, 0) then
					loc_1179_, loc_1189_ = loc_1189_, loc_1179_;
					loc_1189_, loc_1187_ = loc_1187_, loc_1189_;
					loc_1187_, loc_1190_ = loc_1190_, loc_1187_;
					loc_1190_, loc_1188_ = loc_1188_, loc_1190_;
				else
					loc_1179_, loc_1189_ = loc_1189_, loc_1179_;
					loc_1189_, loc_1187_ = loc_1187_, loc_1189_;
					loc_1187_, loc_1190_ = loc_1190_, loc_1187_;
					loc_1190_, loc_1188_ = loc_1188_, loc_1190_;
					rt_store_i32(loc_1183_, loc_1192_, 52, loc_1187_)
				end
				if not (rt_equal_i32(loc_1187_, 0)) then
					rt_store_i32(loc_1183_, loc_1187_, 48, loc_1192_)
				end
				loc_1192_ = buffer_read_i32(loc_1183_[1], loc_1188_, 0);
				if not (rt_not_equal_i32(loc_1192_, loc_1179_)) then
					rt_store_i32(loc_1183_, loc_1188_, 0, loc_1187_)
				end
				loc_1187_ = loc_1189_;
				loc_1188_ = loc_1190_;
				loc_1189_[1](loc_1191_)
				loc_1191_ = buffer_read_i32(loc_1183_[1], loc_1179_, 80);
				loc_1190_[1](loc_1191_, loc_1189_)
				loc_1190_[1](loc_1179_, loc_1189_)
			end
			return rt_or_i32(loc_1180_, loc_1181_), loc_1179_
		end), "i32->i32")
	end)(module_locals[89], module_locals[91], module_locals[117], module_locals[118], module_locals[159], module_locals[162], module_locals[3]);
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[91][1] = (function(loc_1193_, loc_1194_, loc_1195_, loc_1196_, loc_1197_)
		return rt_function_type(--[[fn:fflush]](function(loc_1198_, loc_1199_)
			local loc_1200_, loc_1201_, loc_1202_, loc_1203_, loc_1204_, loc_1205_, loc_1206_, loc_1207_, loc_1208_, loc_1209_, loc_1210_
			if rt_not_equal_i32(loc_1198_, 0) then
				loc_1200_ = loc_1199_;
				loc_1201_ = loc_1198_;
				loc_1202_ = loc_1196_;
				loc_1203_ = loc_1197_;
				loc_1204_ = loc_1193_;
				loc_1205_ = loc_1194_;
				loc_1206_ = loc_1195_;
				loc_1208_ = buffer_read_i32(loc_1203_[1], loc_1201_, 20);
				loc_1209_ = buffer_read_i32(loc_1203_[1], loc_1201_, 24);
				if rt_equal_i32(loc_1208_, loc_1209_) then
					loc_1209_ = 0;
				else
					loc_1209_ = buffer_read_i32(loc_1203_[1], loc_1201_, 32);
					loc_1208_ = rt_table_get_function(loc_1202_, loc_1209_, "i32,i32,i32->i32");
					loc_1209_ = loc_1200_;
					loc_1209_ = loc_1208_(loc_1201_, 0, 0, loc_1209_)
					loc_1209_ = buffer_read_i32(loc_1203_[1], loc_1201_, 20);
					if rt_not_equal_i32(loc_1209_, 0) then
						loc_1209_ = 0;
					else
						loc_1209_ = loc_1201_;
						loc_1209_ = 1;
						loc_1201_ = -1;
					end
				end
				if not (rt_not_equal_i32(loc_1209_, 0)) then
					loc_1207_ = buffer_read_i32(loc_1203_[1], loc_1201_, 4);
					loc_1208_ = buffer_read_i32(loc_1203_[1], loc_1201_, 8);
					if not (rt_equal_i32(loc_1207_, loc_1208_)) then
						loc_1209_ = buffer_read_i32(loc_1203_[1], loc_1201_, 36);
						loc_1209_ = rt_table_get_function(loc_1202_, loc_1209_, "i32,i64,i32->i64");
						loc_1208_ = loc_1209_(loc_1201_, rt_extend_s32_to_i64(bit32_or(loc_1207_ - loc_1208_, 0)), 1, loc_1200_)
					end
					rt_store_i32(loc_1203_, loc_1201_, 24, 0)
					rt_store_i64(loc_1203_, loc_1201_, 16, into_bits_i64(0, 0))
					rt_store_i64(loc_1203_, loc_1201_, 4, into_bits_i64(0, 0))
					loc_1201_ = 0;
				end
			else
				loc_1200_ = loc_1199_;
				loc_1202_ = loc_1196_;
				loc_1203_ = loc_1197_;
				loc_1204_ = loc_1193_;
				loc_1205_ = loc_1194_;
				loc_1206_ = loc_1195_;
				loc_1210_ = loc_1198_;
				loc_1210_ = buffer_read_i32(loc_1203_[1], 0, 10792);
				loc_1201_ = 0;
				if rt_equal_i32(loc_1210_, 0) then
					loc_1208_ = loc_1206_;
					loc_1210_ = loc_1200_;
				else
					loc_1207_ = loc_1204_;
					loc_1208_ = loc_1206_;
					loc_1209_ = loc_1201_;
					loc_1210_ = loc_1200_;
					loc_1204_ = loc_1207_;
					loc_1209_ = buffer_read_i32(loc_1203_[1], 0, 10792);
					loc_1201_ = loc_1207_[1](loc_1209_, loc_1210_)
				end
				loc_1209_ = buffer_read_i32(loc_1203_[1], 0, 10912);
				if not (rt_equal_i32(loc_1209_, 0)) then
					loc_1207_ = loc_1204_;
					loc_1204_ = loc_1207_;
					loc_1209_ = buffer_read_i32(loc_1203_[1], 0, 10912);
					loc_1209_ = loc_1207_[1](loc_1209_, loc_1210_)
					loc_1201_ = rt_or_i32(loc_1209_, loc_1201_);
				end
				loc_1210_ = loc_1205_[1](loc_1210_)
				loc_1207_ = buffer_read_i32(loc_1203_[1], loc_1210_, 0);
				if not (rt_equal_i32(loc_1207_, 0)) then
					repeat
						rt_yield_budget = rt_yield_budget - 1
						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
						loc_1206_ = buffer_read_i32(loc_1203_[1], loc_1207_, 20);
						loc_1210_ = buffer_read_i32(loc_1203_[1], loc_1207_, 24);
						if not (rt_equal_i32(loc_1206_, loc_1210_)) then
							loc_1210_ = loc_1209_;
							loc_1209_ = buffer_read_i32(loc_1203_[1], loc_1207_, 32);
							loc_1209_ = rt_table_get_function(loc_1202_, loc_1209_, "i32,i32,i32->i32");
							loc_1210_ = loc_1209_(loc_1207_, 0, 0, loc_1210_)
							loc_1210_ = buffer_read_i32(loc_1203_[1], loc_1207_, 20);
							if rt_not_equal_i32(loc_1210_, 0) then
								loc_1206_ = buffer_read_i32(loc_1203_[1], loc_1207_, 4);
								loc_1200_ = buffer_read_i32(loc_1203_[1], loc_1207_, 8);
								if not (rt_equal_i32(loc_1206_, loc_1200_)) then
									loc_1210_ = buffer_read_i32(loc_1203_[1], loc_1207_, 36);
									loc_1210_ = rt_table_get_function(loc_1202_, loc_1210_, "i32,i64,i32->i64");
									loc_1206_ = loc_1210_(loc_1207_, rt_extend_s32_to_i64(bit32_or(loc_1206_ - loc_1200_, 0)), 1, loc_1209_)
								end
								rt_store_i32(loc_1203_, loc_1207_, 24, 0)
								rt_store_i64(loc_1203_, loc_1207_, 16, into_bits_i64(0, 0))
								rt_store_i64(loc_1203_, loc_1207_, 4, into_bits_i64(0, 0))
								loc_1206_ = 0;
							else
								loc_1206_ = -1;
							end
							loc_1201_ = rt_or_i32(loc_1206_, loc_1201_);
						end
						loc_1206_ = buffer_read_i32(loc_1203_[1], loc_1207_, 52);
						loc_1207_ = loc_1206_;
					until loc_1206_ == 0
				end
				loc_1206_ = loc_1208_;
				loc_1208_[1](loc_1209_)
			end
			return loc_1201_, loc_1200_
		end), "i32->i32")
	end)(module_locals[91], module_locals[117], module_locals[118], module_locals[162], module_locals[3]);
	module_locals[92] = { nil };
	module_locals[138] = { nil };
	module_locals[92][1] = (function(loc_1211_, loc_1212_)
		return rt_function_type(--[[fn:__fmodeflags]](function(loc_1213_, loc_1214_)
			local loc_1215_, loc_1216_, loc_1217_, loc_1218_, loc_1219_, loc_1220_, loc_1221_, loc_1222_, loc_1223_
			loc_1217_ = rt_load_i32_from_u8(loc_1212_, loc_1213_, 0);
			loc_1218_ = loc_1212_;
			loc_1221_ = (rt_equal_i32(loc_1217_, 114) and 1 or 0);
			loc_1216_ = 335544320;
			loc_1215_ = 67108864;
			loc_1222_ = 268435456;
			if rt_not_equal_i32(loc_1221_, 0) then
				loc_1219_ = loc_1211_;
				loc_1220_ = loc_1213_;
				loc_1223_ = loc_1214_;
			else
				loc_1219_ = loc_1211_;
				loc_1220_ = loc_1213_;
				loc_1223_ = loc_1214_;
				loc_1215_ = loc_1222_;
			end
			loc_1223_ = loc_1219_[1](loc_1220_, 43, loc_1223_)
			if not (rt_not_equal_i32(loc_1223_, 0)) then
				loc_1216_ = loc_1215_;
			end
			loc_1222_ = loc_1219_[1](loc_1220_, 120, loc_1222_)
			loc_1220_ = rt_or_i32(loc_1216_, 16384);
			if not (rt_not_equal_i32(loc_1222_, 0)) then
				loc_1220_ = loc_1216_;
			end
			loc_1216_ = rt_or_i32(loc_1220_, 4096);
			if not (rt_not_equal_i32(loc_1221_, 0)) then
				loc_1220_ = loc_1216_;
			end
			loc_1216_ = rt_or_i32(loc_1220_, 32768);
			if not (rt_equal_i32(loc_1217_, 119)) then
				loc_1216_ = loc_1220_;
			end
			return rt_or_i32(loc_1216_, (rt_equal_i32(loc_1217_, 97) and 1 or 0)), loc_1215_
		end), "i32->i32")
	end)(module_locals[138], module_locals[3]);
	module_locals[93] = { nil };
	module_locals[94] = { nil };
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[93][1] = (function(loc_1224_, loc_1225_, loc_1226_, loc_1227_, loc_1228_, loc_1229_, loc_1230_, loc_1231_)
		return rt_function_type(--[[fn:__wasilibc_populate_preopens]](function(loc_1232_)
			local loc_1233_, loc_1234_, loc_1235_, loc_1236_, loc_1237_, loc_1238_, loc_1239_, loc_1240_, loc_1241_, loc_1242_, loc_1243_, loc_1244_, loc_1245_, loc_1246_, loc_1247_
			loc_1247_ = loc_1230_[1];
			loc_1234_ = loc_1230_;
			loc_1242_ = bit32_or(loc_1247_ - 16, 0);
			loc_1234_[1] = loc_1242_;
			loc_1247_ = rt_load_i32_from_u8(loc_1231_, 0, 27532);
			loc_1235_ = loc_1231_;
			loc_1243_ = 0;
			loc_1244_ = 0;
			loc_1245_ = 0;
			if rt_not_equal_i32(rt_and_i32(loc_1247_, 1), 0) then
				loc_1233_ = loc_1232_;
				loc_1236_ = loc_1224_;
				loc_1237_ = loc_1225_;
				loc_1238_ = loc_1226_;
				loc_1239_ = loc_1227_;
				loc_1240_ = loc_1228_;
				loc_1241_ = loc_1229_;
				loc_1243_ = 0;
			else
				loc_1233_ = loc_1232_;
				loc_1236_ = loc_1224_;
				loc_1237_ = loc_1225_;
				loc_1238_ = loc_1226_;
				loc_1239_ = loc_1227_;
				loc_1240_ = loc_1228_;
				loc_1241_ = loc_1229_;
				loc_1247_ = rt_load_i32_from_u8(loc_1235_, 0, 27532);
				if rt_not_equal_i32(rt_and_i32(loc_1247_, 1), 0) then
					loc_1243_, loc_1245_ = loc_1245_, loc_1243_;
					loc_1243_ = 0;
				else
					loc_1246_ = loc_1244_;
					loc_1247_ = loc_1233_;
					loc_1243_, loc_1245_ = loc_1245_, loc_1243_;
					loc_1244_ = loc_1236_;
					loc_1233_ = loc_1245_;
					loc_1236_ = loc_1246_;
					loc_1246_ = 3;
					loc_1245_ = loc_1247_;
					repeat
						rt_yield_budget = rt_yield_budget - 1
						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
						loc_1247_ = loc_1243_;
						loc_1247_ = loc_1245_;
						loc_1243_ = loc_1237_[1](loc_1246_, bit32_or(loc_1242_ + 8, 0), loc_1247_)
						if rt_equal_i32(loc_1243_, 0) then
							loc_1247_ = loc_1233_;
							loc_1233_ = rt_load_i32_from_u8(loc_1235_, loc_1242_, 8);
							if rt_not_equal_i32(loc_1233_, 0) then
								loc_1233_ = 0;
							else
								loc_1233_ = buffer_read_i32(loc_1235_[1], loc_1242_, 12);
								loc_1243_ = loc_1240_[1](bit32_or(loc_1233_ + 1, 0), loc_1245_)
								if rt_equal_i32(loc_1243_, 0) then
									loc_1233_ = 1;
									loc_1247_ = 0;
									loc_1236_ = 2;
								else
									loc_1233_ = loc_1238_[1](loc_1246_, loc_1243_, loc_1233_, loc_1245_)
									if rt_not_equal_i32(loc_1233_, 0) then
										loc_1233_ = 1;
										loc_1247_ = 0;
										loc_1236_ = 1;
									else
										loc_1233_ = buffer_read_i32(loc_1235_[1], loc_1242_, 12);
										rt_store_i32_into_i8(loc_1235_, bit32_or(loc_1243_ + loc_1233_, 0), 0, 0)
										loc_1233_ = loc_1239_[1](loc_1246_, loc_1243_, loc_1245_)
										loc_1241_[1](loc_1243_, loc_1245_)
										if rt_not_equal_i32(loc_1233_, 0) then
											loc_1233_ = 1;
											loc_1247_ = 0;
											loc_1236_ = 2;
										else
											loc_1233_ = 0;
										end
									end
								end
							end
							if not (rt_not_equal_i32(loc_1233_, 0)) then
								loc_1247_ = 1;
								loc_1236_ = 65535;
								loc_1246_ = bit32_or(loc_1246_ + 1, 0);
							end
						else
							loc_1247_ = loc_1233_;
							loc_1247_ = 0;
							loc_1236_ = 0;
						end
						loc_1233_ = loc_1247_;
					until loc_1247_ == 0
					if (loc_1236_) >= 0 and (loc_1236_) < 2 then
						if (loc_1236_) < 1 then
							if rt_not_equal_i32(loc_1243_, 8) then
								loc_1233_ = loc_1245_;
								loc_1236_ = loc_1244_;
								loc_1245_ = 0;
							else
								loc_1233_ = loc_1245_;
								loc_1236_ = loc_1244_;
								rt_store_i32_into_i8(loc_1235_, 0, 27532, 1)
								loc_1245_ = 1;
							end
						else
							loc_1244_, loc_1245_ = loc_1245_, loc_1244_;
							loc_1236_ = loc_1245_;
							loc_1245_ = 0;
							loc_1233_ = loc_1244_;
						end
					else
						loc_1236_ = loc_1244_;
						loc_1244_[1](70, loc_1245_)
						loc_1245_ = 2;
						loc_1244_ = error('unreachable code');
					end
					if (loc_1245_) >= 0 and (loc_1245_) < 2 then
						if (loc_1245_) < 1 then
							loc_1244_ = loc_1236_;
							loc_1236_ = loc_1244_;
							loc_1245_ = loc_1233_;
							loc_1244_[1](71, loc_1245_)
							loc_1243_ = 1;
							loc_1245_ = error('unreachable code');
						else
							loc_1243_ = 0;
						end
					else
						loc_1243_ = 1;
					end
				end
			end
			if not (rt_not_equal_i32(loc_1243_, 0)) then
				loc_1234_[1] = bit32_or(loc_1242_ + 16, 0);
			end
			return loc_1233_
		end), "->")
	end)(module_locals[72], module_locals[79], module_locals[80], module_locals[94], module_locals[156], module_locals[159], module_locals[164], module_locals[3]);
	module_locals[140] = { nil };
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[94][1] = (function(loc_1248_, loc_1249_, loc_1250_, loc_1251_)
		return rt_function_type(--[[fn:internal_register_preopened_fd_unlocked]](function(loc_1252_, loc_1253_, loc_1254_)
			local loc_1255_, loc_1256_, loc_1257_, loc_1258_, loc_1259_, loc_1260_, loc_1261_, loc_1262_, loc_1263_, loc_1264_, loc_1265_, loc_1266_
			loc_1262_ = buffer_read_i32(loc_1251_[1], 0, 27524);
			loc_1257_ = loc_1251_;
			loc_1266_ = buffer_read_i32(loc_1257_[1], 0, 27536);
			loc_1263_ = 0;
			if rt_not_equal_i32(loc_1262_, loc_1266_) then
				loc_1255_ = loc_1254_;
				loc_1256_ = loc_1252_;
				loc_1258_ = loc_1248_;
				loc_1259_ = loc_1249_;
				loc_1260_ = loc_1250_;
				loc_1261_ = loc_1253_;
				loc_1264_ = 0;
			else
				loc_1255_ = loc_1254_;
				loc_1256_ = loc_1252_;
				loc_1258_ = loc_1248_;
				loc_1259_ = loc_1249_;
				loc_1260_ = loc_1250_;
				loc_1261_ = loc_1253_;
				loc_1266_ = loc_1263_;
				loc_1263_ = buffer_read_i32(loc_1257_[1], 0, 27528);
				loc_1264_ = 8;
				loc_1266_ = rt_shift_left_i32(loc_1262_, 1);
				loc_1265_ = 4;
				if rt_not_equal_i32(loc_1262_, 0) then
					loc_1255_, loc_1259_ = loc_1259_, loc_1255_;
					loc_1259_, loc_1265_ = loc_1265_, loc_1259_;
				else
					loc_1255_, loc_1259_ = loc_1259_, loc_1255_;
					loc_1259_, loc_1265_ = loc_1265_, loc_1259_;
					loc_1266_ = loc_1259_;
				end
				loc_1265_ = loc_1260_[1](loc_1264_, loc_1266_, loc_1265_)
				if rt_not_equal_i32(loc_1265_, 0) then
					loc_1259_ = rt_shift_left_i32(loc_1262_, 3);
					if not (rt_equal_i32(loc_1259_, 0)) then
						rt_memory_copy(loc_1257_, loc_1265_, loc_1257_, loc_1263_, loc_1259_)
					end
					loc_1259_ = loc_1255_;
					rt_store_i32(loc_1257_, 0, 27536, loc_1266_)
					rt_store_i32(loc_1257_, 0, 27528, loc_1265_)
					loc_1255_[1](loc_1263_, loc_1264_)
					loc_1264_ = 0;
				else
					loc_1259_ = loc_1265_;
					loc_1265_ = loc_1256_;
					loc_1264_, loc_1266_ = loc_1266_, loc_1264_;
					loc_1259_ = loc_1255_;
					loc_1264_ = 1;
					loc_1256_ = -1;
					loc_1255_ = loc_1266_;
				end
			end
			if not (rt_not_equal_i32(loc_1264_, 0)) then
				loc_1264_ = loc_1255_;
				loc_1256_, loc_1261_ = loc_1261_, loc_1256_;
				loc_1255_ = loc_1256_;
				loc_1256_ = loc_1262_;
				loc_1262_ = loc_1263_;
				loc_1263_ = loc_1264_;
				repeat
					rt_yield_budget = rt_yield_budget - 1
					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
					loc_1264_ = loc_1262_;
					loc_1264_ = rt_load_i32_from_u8(loc_1257_, loc_1255_, 0);
					loc_1264_ = bit32_or(loc_1264_ + -46, 0);
					if (loc_1264_) >= 0 and (loc_1264_) < 2 then
						if (loc_1264_) < 1 then
							loc_1262_ = loc_1255_;
							loc_1264_ = loc_1255_;
							loc_1264_ = rt_load_i32_from_u8(loc_1257_, loc_1262_, 1);
							loc_1255_ = bit32_or(loc_1262_ + 1, 0);
							if rt_equal_i32(loc_1264_, 0) then
								loc_1264_ = 1;
							else
								if rt_not_equal_i32(loc_1264_, 47) then
									loc_1264_ = 0;
								else
									loc_1264_ = loc_1255_;
									loc_1264_ = 1;
									loc_1255_ = bit32_or(loc_1262_ + 2, 0);
								end
							end
						else
							loc_1262_ = loc_1255_;
							loc_1264_ = loc_1255_;
							loc_1264_ = 1;
							loc_1255_ = bit32_or(loc_1262_ + 1, 0);
						end
					else
						loc_1262_ = loc_1255_;
						loc_1264_ = 0;
					end
				until loc_1264_ == 0
				loc_1262_ = loc_1258_[1](loc_1262_, loc_1263_)
				if rt_not_equal_i32(loc_1262_, 0) then
					rt_store_i32(loc_1257_, 0, 27524, bit32_or(loc_1256_ + 1, 0))
					loc_1263_ = buffer_read_i32(loc_1257_[1], 0, 27528);
					loc_1263_ = bit32_or(loc_1263_ + rt_shift_left_i32(loc_1256_, 3), 0);
					rt_store_i32(loc_1257_, loc_1263_, 4, loc_1261_)
					rt_store_i32(loc_1257_, loc_1263_, 0, loc_1262_)
					loc_1256_ = 0;
				else
					loc_1263_ = loc_1261_;
					loc_1261_ = loc_1262_;
					loc_1262_ = loc_1256_;
					loc_1256_ = -1;
				end
			end
			return loc_1256_, loc_1255_
		end), "i32,i32->i32")
	end)(module_locals[140], module_locals[159], module_locals[161], module_locals[3]);
	module_locals[95] = { nil };
	module_locals[96] = { nil };
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[95][1] = (function(loc_1267_, loc_1268_, loc_1269_, loc_1270_)
		return rt_function_type(--[[fn:__wasilibc_find_relpath]](function(loc_1271_, loc_1272_, loc_1273_, loc_1274_, loc_1275_)
			local loc_1276_, loc_1277_, loc_1278_, loc_1279_, loc_1280_, loc_1281_, loc_1282_, loc_1283_, loc_1284_, loc_1285_
			loc_1285_ = loc_1269_[1];
			loc_1278_ = loc_1269_;
			loc_1280_ = bit32_or(loc_1285_ - 16, 0);
			loc_1278_[1] = loc_1280_;
			rt_store_i32(loc_1270_, loc_1280_, 12, loc_1274_)
			loc_1279_ = loc_1270_;
			if rt_equal_i32(0, 0) then
				loc_1276_ = loc_1273_;
				loc_1277_ = loc_1275_;
				loc_1281_ = loc_1267_;
				loc_1283_ = loc_1272_;
				loc_1284_ = loc_1271_;
				loc_1285_ = loc_1268_;
				loc_1282_ = loc_1285_;
				loc_1277_ = loc_1285_[1](loc_1284_, loc_1283_, loc_1276_, loc_1277_)
			else
				loc_1276_ = loc_1273_;
				loc_1277_ = loc_1267_;
				loc_1282_ = loc_1268_;
				loc_1283_ = loc_1272_;
				loc_1284_ = loc_1271_;
				loc_1285_ = loc_1275_;
				loc_1281_ = loc_1277_;
				loc_1277_ = loc_1277_[1](loc_1284_, loc_1283_, loc_1276_, bit32_or(loc_1280_ + 12, 0), 0, loc_1285_)
			end
			loc_1278_[1] = bit32_or(loc_1280_ + 16, 0);
			return loc_1277_, loc_1276_
		end), "i32,i32,i32,i32->i32")
	end)(module_locals[30], module_locals[96], module_locals[164], module_locals[3]);
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[96][1] = (function(loc_1286_, loc_1287_, loc_1288_, loc_1289_)
		return rt_function_type(--[[fn:__wasilibc_find_abspath]](function(loc_1290_, loc_1291_, loc_1292_, loc_1293_)
			local loc_1294_, loc_1295_, loc_1296_, loc_1297_, loc_1298_, loc_1299_, loc_1300_, loc_1301_, loc_1302_, loc_1303_, loc_1304_, loc_1305_, loc_1306_, loc_1307_, loc_1308_, loc_1309_, loc_1310_, loc_1311_, loc_1312_
			loc_1297_ = loc_1286_;
			loc_1298_ = loc_1287_;
			loc_1299_ = loc_1288_;
			loc_1296_ = loc_1289_;
			loc_1312_ = loc_1293_;
			loc_1286_[1](loc_1312_)
			loc_1300_ = 0;
			loc_1295_ = bit32_or(loc_1290_ + -1, 0);
			loc_1301_ = loc_1291_;
			loc_1302_ = loc_1292_;
			repeat
				rt_yield_budget = rt_yield_budget - 1
				if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
				loc_1295_ = bit32_or(loc_1295_ + 1, 0);
				loc_1312_ = rt_load_i32_from_u8(loc_1296_, loc_1295_, 0);
			until not (rt_equal_i32(loc_1312_, 47))
			loc_1304_ = buffer_read_i32(loc_1296_[1], 0, 27524);
			loc_1303_ = 0;
			if rt_equal_i32(loc_1304_, 0) then
				loc_1300_ = 0;
			else
				loc_1310_ = loc_1302_;
				loc_1311_ = loc_1303_;
				loc_1312_ = loc_1304_;
				loc_1306_ = buffer_read_i32(loc_1296_[1], 0, 27528);
				loc_1302_ = loc_1295_;
				loc_1305_ = loc_1301_;
				loc_1303_ = loc_1310_;
				loc_1304_ = loc_1311_;
				loc_1301_ = loc_1312_;
				loc_1295_ = -1;
				repeat
					rt_yield_budget = rt_yield_budget - 1
					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
					loc_1312_ = bit32_or(loc_1306_ + rt_shift_left_i32(loc_1301_, 3), 0);
					loc_1308_ = buffer_read_i32(loc_1296_[1], bit32_or(loc_1312_ + -8, 0), 0);
					loc_1311_ = loc_1294_;
					loc_1309_ = loc_1299_[1](loc_1308_, loc_1311_)
					if rt_equal_i32(loc_1295_, -1) then
						loc_1307_ = loc_1301_;
						loc_1301_ = loc_1312_;
						loc_1312_ = 0;
					else
						loc_1307_ = loc_1301_;
						loc_1301_ = loc_1312_;
						if rt_less_than_equal_u32(loc_1309_, loc_1304_) then
							loc_1312_ = 1;
						else
							loc_1312_ = 0;
						end
					end
					if not (rt_not_equal_i32(loc_1312_, 0)) then
						loc_1310_ = rt_load_i32_from_u8(loc_1296_, loc_1302_, 0);
						if rt_not_equal_i32(loc_1309_, 0) then
							loc_1301_, loc_1309_ = loc_1309_, loc_1301_;
							loc_1312_ = 0;
						else
							loc_1301_, loc_1309_ = loc_1309_, loc_1301_;
							if rt_not_equal_i32(rt_and_i32(loc_1310_, 255), 47) then
								loc_1312_ = 1;
							else
								loc_1312_ = 0;
							end
						end
						if rt_not_equal_i32(loc_1312_, 0) then
							loc_1310_ = 0;
						else
							loc_1312_ = loc_1294_;
							loc_1312_ = loc_1298_[1](loc_1302_, loc_1308_, loc_1301_, loc_1312_)
							if rt_not_equal_i32(loc_1312_, 0) then
								loc_1310_ = 1;
							else
								if not (rt_equal_i32(loc_1301_, 0)) then
									loc_1311_ = loc_1301_;
									loc_1312_ = loc_1308_;
									loc_1308_ = loc_1312_;
									loc_1301_ = loc_1311_;
									loc_1310_ = loc_1311_;
									loc_1311_ = bit32_or(loc_1312_ + -1, 0);
									repeat
										rt_yield_budget = rt_yield_budget - 1
										if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
										loc_1312_ = loc_1300_;
										loc_1312_ = rt_load_i32_from_u8(loc_1296_, bit32_or(loc_1311_ + loc_1310_, 0), 0);
										if rt_not_equal_i32(loc_1312_, 47) then
											loc_1312_ = 0;
											loc_1300_ = 1;
										else
											loc_1310_ = bit32_or(loc_1310_ + -1, 0);
											if rt_not_equal_i32(loc_1310_, 0) then
												loc_1312_ = 1;
												loc_1300_ = 65535;
											else
												loc_1312_ = 0;
												loc_1300_ = 0;
											end
										end
									until loc_1312_ == 0
									if not (rt_not_equal_i32(loc_1300_, 0)) then
										loc_1310_ = 0;
									end
									loc_1310_ = rt_load_i32_from_u8(loc_1296_, bit32_or(loc_1302_ + loc_1310_, 0), 0);
								end
								loc_1310_ = rt_and_i32(loc_1310_, 255);
								if rt_equal_i32(loc_1310_, 47) then
									loc_1310_ = 0;
								else
									if rt_not_equal_i32(loc_1310_, 0) then
										loc_1310_ = 1;
									else
										loc_1310_ = 0;
									end
								end
							end
						end
						if not (rt_not_equal_i32(loc_1310_, 0)) then
							rt_store_i32(loc_1296_, loc_1305_, 0, loc_1308_)
							loc_1295_ = buffer_read_i32(loc_1296_[1], bit32_or(loc_1309_ + -4, 0), 0);
							loc_1304_ = loc_1301_;
						end
					end
					loc_1307_ = bit32_or(loc_1307_ + -1, 0);
					loc_1301_ = loc_1307_;
				until loc_1307_ == 0
				if rt_not_equal_i32(loc_1295_, -1) then
					loc_1304_ = bit32_or(bit32_or(loc_1302_ + loc_1304_, 0) + -1, 0);
					repeat
						rt_yield_budget = rt_yield_budget - 1
						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
						loc_1302_ = loc_1301_;
						loc_1304_ = bit32_or(loc_1304_ + 1, 0);
						loc_1302_ = rt_load_i32_from_u8(loc_1296_, loc_1304_, 0);
						loc_1301_ = loc_1302_;
					until not (rt_equal_i32(loc_1302_, 47))
					loc_1302_ = 1631;
					if not (rt_not_equal_i32(loc_1301_, 0)) then
						loc_1304_ = loc_1302_;
					end
					rt_store_i32(loc_1296_, loc_1303_, 0, loc_1304_)
					loc_1300_ = 1;
				else
					loc_1300_ = loc_1295_;
					loc_1303_, loc_1304_ = loc_1304_, loc_1303_;
					loc_1300_ = 0;
					loc_1295_ = loc_1302_;
				end
			end
			if not (rt_not_equal_i32(loc_1300_, 0)) then
				rt_store_i32(loc_1296_, 0, 27520, 44)
				loc_1295_ = -1;
			end
			return loc_1295_, loc_1294_
		end), "i32,i32,i32->i32")
	end)(module_locals[93], module_locals[137], module_locals[141], module_locals[3]);
	module_locals[97] = { nil };
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[97][1] = (function(loc_1313_, loc_1314_, loc_1315_, loc_1316_)
		return rt_function_type(--[[fn:__wasilibc_nocwd_openat_nomode]](function(loc_1317_, loc_1318_, loc_1319_, loc_1320_)
			local loc_1321_, loc_1322_, loc_1323_, loc_1324_, loc_1325_, loc_1326_, loc_1327_, loc_1328_, loc_1329_, loc_1330_, loc_1331_, loc_1332_
			loc_1332_ = loc_1315_[1];
			loc_1323_ = loc_1315_;
			loc_1325_ = bit32_or(loc_1332_ - 32, 0);
			loc_1323_[1] = loc_1325_;
			loc_1322_ = rt_shift_right_u32(bit32_or(rt_and_i32(loc_1319_, 503316480) + -33554432, 0), 25);
			if rt_greater_than_u32(loc_1322_, 9) then
				loc_1321_ = loc_1320_;
				loc_1324_ = loc_1316_;
				loc_1326_ = loc_1313_;
				loc_1327_ = loc_1314_;
				loc_1328_ = loc_1317_;
				loc_1329_ = loc_1318_;
				loc_1330_ = loc_1319_;
				loc_1328_ = 0;
			else
				loc_1321_ = loc_1320_;
				loc_1324_ = loc_1316_;
				loc_1326_ = loc_1313_;
				loc_1327_ = loc_1314_;
				loc_1328_ = loc_1317_;
				loc_1329_ = loc_1318_;
				loc_1330_ = loc_1319_;
				loc_1322_ = rt_shift_left_i32(1, loc_1322_);
				if rt_not_equal_i32(rt_and_i32(loc_1322_, 642), 0) then
					loc_1328_, loc_1330_ = loc_1330_, loc_1328_;
					loc_1332_ = into_bits_i64(4290772670, 4294967295);
					loc_1331_ = into_bits_i64(4290756284, 4294967295);
					if not (rt_not_equal_i32(rt_and_i32(loc_1328_, 67108864), 0)) then
						loc_1332_ = loc_1331_;
					end
					loc_1331_ = rt_or_i64(loc_1332_, into_bits_i64(4194625, 0));
					if not (rt_not_equal_i32(rt_and_i32(loc_1328_, 268435456), 0)) then
						loc_1331_ = loc_1332_;
					end
					loc_1332_ = 0;
				else
					loc_1328_, loc_1330_ = loc_1330_, loc_1328_;
					loc_1331_ = into_bits_i64(4290756284, 4294967295);
					if rt_not_equal_i32(rt_and_i32(loc_1322_, 9), 0) then
						loc_1332_ = 0;
					else
						loc_1332_ = 1;
					end
				end
				if rt_not_equal_i32(loc_1332_, 0) then
					loc_1328_ = 0;
				else
					loc_1322_ = loc_1321_;
					loc_1321_ = loc_1326_[1](loc_1330_, bit32_or(loc_1325_ + 8, 0), loc_1322_)
					if rt_equal_i32(loc_1321_, 0) then
						loc_1321_, loc_1330_ = loc_1330_, loc_1321_;
						loc_1322_, loc_1329_ = loc_1329_, loc_1322_;
						loc_1329_, loc_1331_ = loc_1331_, loc_1329_;
						loc_1330_ = rt_load_i64(loc_1324_, loc_1325_, 24);
						loc_1331_ = loc_1327_[1](loc_1321_, rt_and_i32(rt_shift_right_u32(rt_exclusive_or_i32(loc_1328_, -1), 24), 1), loc_1322_, rt_and_i32(rt_shift_right_u32(loc_1328_, 12), 4095), rt_and_i64(loc_1330_, loc_1329_), loc_1330_, rt_and_i32(loc_1328_, 4095), bit32_or(loc_1325_ + 4, 0), loc_1331_)
						loc_1330_ = -1;
						if rt_equal_i32(loc_1331_, 0) then
							loc_1322_ = buffer_read_i32(loc_1324_[1], loc_1325_, 4);
							loc_1328_ = 1;
						else
							rt_store_i32(loc_1324_, 0, 27520, loc_1331_)
							loc_1328_ = 1;
							loc_1322_ = loc_1330_;
						end
					else
						loc_1321_, loc_1331_ = loc_1331_, loc_1321_;
						loc_1331_, loc_1322_ = loc_1322_, loc_1331_;
						loc_1322_, loc_1328_ = loc_1328_, loc_1322_;
						loc_1328_, loc_1329_ = loc_1329_, loc_1328_;
						loc_1329_, loc_1330_ = loc_1330_, loc_1329_;
						rt_store_i32(loc_1324_, 0, 27520, loc_1330_)
						loc_1328_ = 1;
						loc_1322_ = -1;
						loc_1321_ = loc_1331_;
					end
				end
			end
			if not (rt_not_equal_i32(loc_1328_, 0)) then
				rt_store_i32(loc_1324_, 0, 27520, 28)
				loc_1322_ = -1;
			end
			loc_1323_[1] = bit32_or(loc_1325_ + 32, 0);
			return loc_1322_, loc_1321_
		end), "i32,i32,i32->i32")
	end)(module_locals[77], module_locals[84], module_locals[164], module_locals[3]);
	module_locals[98] = { nil };
	module_locals[98][1] = (function(loc_1333_, loc_1334_, loc_1335_)
		return rt_function_type(--[[fn:close]](function(loc_1336_, loc_1337_)
			local loc_1338_, loc_1339_, loc_1340_, loc_1341_, loc_1342_
			loc_1340_ = loc_1335_;
			loc_1342_ = loc_1337_;
			loc_1334_[1](loc_1342_)
			loc_1339_ = loc_1333_[1](loc_1336_, loc_1342_)
			if rt_not_equal_i32(loc_1339_, 0) then
				loc_1341_ = loc_1333_;
				loc_1342_ = loc_1334_;
				rt_store_i32(loc_1340_, 0, 27520, loc_1339_)
				loc_1339_ = -1;
			else
				loc_1341_ = loc_1333_;
				loc_1342_ = loc_1334_;
				loc_1339_ = 0;
			end
			return loc_1339_, loc_1338_
		end), "i32->i32")
	end)(module_locals[76], module_locals[93], module_locals[3]);
	module_locals[99] = { nil };
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[99][1] = (function(loc_1343_, loc_1344_, loc_1345_, loc_1346_, loc_1347_)
		return rt_function_type(--[[fn:__wasilibc_open_nomode]](function(loc_1348_, loc_1349_, loc_1350_)
			local loc_1351_, loc_1352_, loc_1353_, loc_1354_, loc_1355_, loc_1356_, loc_1357_, loc_1358_, loc_1359_, loc_1360_, loc_1361_
			loc_1361_ = loc_1346_[1];
			loc_1353_ = loc_1346_;
			loc_1355_ = bit32_or(loc_1361_ - 16, 0);
			loc_1353_[1] = loc_1355_;
			if rt_equal_i32(0, 0) then
				loc_1351_ = loc_1344_;
				loc_1352_ = loc_1348_;
				loc_1354_ = loc_1347_;
				loc_1356_ = loc_1343_;
				loc_1359_ = loc_1349_;
				loc_1360_ = loc_1350_;
				loc_1361_ = loc_1345_;
				loc_1357_ = loc_1351_;
				loc_1358_ = buffer_read_i32(loc_1354_[1], 0, 27544);
				loc_1360_ = loc_1351_[1](loc_1352_, bit32_or(loc_1355_ + 12, 0), 27540, loc_1358_, loc_1360_)
			else
				loc_1351_ = loc_1344_;
				loc_1352_ = loc_1348_;
				loc_1354_ = loc_1347_;
				loc_1358_ = loc_1343_;
				loc_1359_ = loc_1349_;
				loc_1360_ = loc_1350_;
				loc_1361_ = loc_1345_;
				loc_1356_ = loc_1358_;
				loc_1357_ = loc_1351_;
				loc_1360_ = loc_1358_[1](loc_1352_, bit32_or(loc_1355_ + 12, 0), 27540, 27544, 1, loc_1360_)
			end
			loc_1358_ = -1;
			if rt_not_equal_i32(loc_1360_, -1) then
				loc_1358_ = loc_1361_;
				loc_1351_ = buffer_read_i32(loc_1354_[1], 0, 27540);
				loc_1352_ = loc_1361_[1](loc_1360_, loc_1351_, loc_1359_, loc_1352_)
			else
				loc_1352_, loc_1359_ = loc_1359_, loc_1352_;
				loc_1359_, loc_1361_ = loc_1361_, loc_1359_;
				loc_1358_, loc_1360_ = loc_1360_, loc_1358_;
				loc_1358_ = loc_1359_;
				rt_store_i32(loc_1354_, 0, 27520, 44)
				loc_1352_ = loc_1360_;
				loc_1351_ = loc_1361_;
			end
			loc_1353_[1] = bit32_or(loc_1355_ + 16, 0);
			return loc_1352_, loc_1351_
		end), "i32,i32->i32")
	end)(module_locals[30], module_locals[95], module_locals[97], module_locals[164], module_locals[3]);
	module_locals[100] = { nil };
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[100][1] = (function(loc_1362_, loc_1363_, loc_1364_, loc_1365_)
		return rt_function_type(--[[fn:fcntl]](function(loc_1366_, loc_1367_, loc_1368_, loc_1369_)
			local loc_1370_, loc_1371_, loc_1372_, loc_1373_, loc_1374_, loc_1375_, loc_1376_, loc_1377_, loc_1378_
			loc_1378_ = loc_1364_[1];
			loc_1372_ = loc_1364_;
			loc_1374_ = bit32_or(loc_1378_ - 32, 0);
			loc_1372_[1] = loc_1374_;
			loc_1378_ = bit32_or(loc_1367_ + -1, 0);
			if (loc_1378_) >= 0 and (loc_1378_) < 4 then
				if (loc_1378_) < 2 then
					if (loc_1378_) < 1 then
						loc_1370_ = loc_1369_;
						loc_1371_ = loc_1367_;
						loc_1373_ = loc_1365_;
						loc_1375_ = loc_1362_;
						loc_1376_ = loc_1363_;
						loc_1377_ = loc_1368_;
						loc_1378_ = loc_1366_;
						loc_1377_ = 1;
					else
						loc_1370_ = loc_1369_;
						loc_1371_ = loc_1368_;
						loc_1373_ = loc_1365_;
						loc_1375_ = loc_1362_;
						loc_1376_ = loc_1363_;
						loc_1377_ = loc_1367_;
						loc_1378_ = loc_1366_;
						loc_1377_ = 1;
						loc_1371_ = 0;
					end
				elseif (loc_1378_) > 2 then
					loc_1370_ = loc_1369_;
					loc_1371_ = loc_1367_;
					loc_1373_ = loc_1365_;
					loc_1375_ = loc_1362_;
					loc_1376_ = loc_1363_;
					loc_1377_ = loc_1366_;
					loc_1378_ = loc_1368_;
					rt_store_i32(loc_1373_, loc_1374_, 8, bit32_or(loc_1378_ + 4, 0))
					loc_1371_ = buffer_read_i32(loc_1373_[1], loc_1378_, 0);
					loc_1378_ = loc_1370_;
					loc_1371_ = loc_1376_[1](loc_1377_, rt_and_i32(loc_1371_, 4095), loc_1378_)
					if rt_not_equal_i32(loc_1371_, 0) then
						rt_store_i32(loc_1373_, 0, 27520, loc_1371_)
						loc_1377_ = 0;
					else
						loc_1378_ = loc_1371_;
						loc_1377_ = 1;
						loc_1371_ = 0;
					end
				else
					loc_1370_ = loc_1369_;
					loc_1371_ = loc_1368_;
					loc_1373_ = loc_1365_;
					loc_1375_ = loc_1362_;
					loc_1376_ = loc_1363_;
					loc_1377_ = loc_1366_;
					loc_1378_ = loc_1367_;
					loc_1378_ = loc_1370_;
					loc_1378_ = loc_1375_[1](loc_1377_, bit32_or(loc_1374_ + 8, 0), loc_1378_)
					if rt_equal_i32(loc_1378_, 0) then
						loc_1371_ = rt_load_i64(loc_1373_, loc_1374_, 16);
						loc_1378_ = rt_load_i32_from_u16(loc_1373_, loc_1374_, 10);
						loc_1377_ = rt_and_i64(loc_1371_, into_bits_i64(64, 0));
						if rt_equal_i64_constant(rt_and_i64(loc_1371_, into_bits_i64(16386, 0)), 0, 0) then
							if rt_equal_i64_constant(loc_1377_, 0, 0) then
								loc_1377_ = 1;
								loc_1371_ = rt_or_i32(loc_1378_, 134217728);
							else
								loc_1377_ = 1;
								loc_1371_ = rt_or_i32(loc_1378_, 268435456);
							end
						else
							if rt_equal_i64_constant(loc_1377_, 0, 0) then
								loc_1377_ = 1;
								loc_1371_ = rt_or_i32(loc_1378_, 67108864);
							else
								loc_1377_ = 1;
								loc_1371_ = rt_or_i32(loc_1378_, 335544320);
							end
						end
					else
						rt_store_i32(loc_1373_, 0, 27520, loc_1378_)
						loc_1377_ = 0;
						loc_1371_ = loc_1378_;
					end
				end
			else
				loc_1370_ = loc_1369_;
				loc_1371_ = loc_1367_;
				loc_1373_ = loc_1365_;
				loc_1375_ = loc_1362_;
				loc_1376_ = loc_1363_;
				loc_1377_ = loc_1366_;
				loc_1378_ = loc_1368_;
				rt_store_i32(loc_1373_, 0, 27520, 28)
				loc_1377_ = 0;
			end
			if not (rt_not_equal_i32(loc_1377_, 0)) then
				loc_1371_ = -1;
			end
			loc_1372_[1] = bit32_or(loc_1374_ + 32, 0);
			return loc_1371_, loc_1370_
		end), "i32,i32,i32->i32")
	end)(module_locals[77], module_locals[78], module_locals[164], module_locals[3]);
	module_locals[101] = { nil };
	module_locals[101][1] = (function(loc_1379_, loc_1380_, loc_1381_)
		return rt_function_type(--[[fn:__isatty]](function(loc_1382_, loc_1383_)
			local loc_1384_, loc_1385_, loc_1386_, loc_1387_, loc_1388_, loc_1389_, loc_1390_, loc_1391_
			loc_1391_ = loc_1380_[1];
			loc_1386_ = loc_1380_;
			loc_1388_ = bit32_or(loc_1391_ - 32, 0);
			loc_1386_[1] = loc_1388_;
			loc_1387_ = loc_1381_;
			loc_1391_ = loc_1383_;
			loc_1390_ = loc_1379_[1](loc_1382_, bit32_or(loc_1388_ + 8, 0), loc_1391_)
			loc_1385_ = 0;
			if rt_not_equal_i32(loc_1390_, 0) then
				loc_1389_ = loc_1379_;
				loc_1391_ = 0;
			else
				loc_1389_ = loc_1379_;
				loc_1391_ = loc_1390_;
				loc_1391_ = rt_load_i32_from_u8(loc_1387_, loc_1388_, 8);
				loc_1390_ = 59;
				if rt_not_equal_i32(loc_1391_, 2) then
					loc_1391_ = 0;
				else
					loc_1391_ = rt_load_i32_from_u8(loc_1387_, loc_1388_, 16);
					if rt_not_equal_i32(rt_and_i32(loc_1391_, 36), 0) then
						loc_1391_ = 0;
					else
						loc_1391_ = loc_1385_;
						loc_1391_ = 1;
						loc_1385_ = 1;
					end
				end
			end
			if not (rt_not_equal_i32(loc_1391_, 0)) then
				rt_store_i32(loc_1387_, 0, 27520, loc_1390_)
				loc_1385_ = 0;
			end
			loc_1386_[1] = bit32_or(loc_1388_ + 32, 0);
			return loc_1385_, loc_1384_
		end), "i32->i32")
	end)(module_locals[77], module_locals[164], module_locals[3]);
	module_locals[102] = { nil };
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[102][1] = (function(loc_1392_, loc_1393_, loc_1394_)
		return rt_function_type(--[[fn:__lseek]](function(loc_1395_, loc_1396_, loc_1397_, loc_1398_)
			local loc_1399_, loc_1400_, loc_1401_, loc_1402_, loc_1403_, loc_1404_, loc_1405_, loc_1406_
			loc_1406_ = loc_1393_[1];
			loc_1401_ = loc_1393_;
			loc_1403_ = bit32_or(loc_1406_ - 16, 0);
			loc_1401_[1] = loc_1403_;
			loc_1402_ = loc_1394_;
			loc_1406_ = loc_1398_;
			loc_1400_ = loc_1392_[1](loc_1395_, loc_1396_, rt_and_i32(loc_1397_, 255), bit32_or(loc_1403_ + 8, 0), loc_1406_)
			if rt_equal_i32(loc_1400_, 0) then
				loc_1404_ = loc_1392_;
				loc_1400_ = rt_load_i64(loc_1402_, loc_1403_, 8);
			else
				loc_1404_ = loc_1392_;
				loc_1406_ = loc_1400_;
				loc_1405_ = 0;
				loc_1400_ = 70;
				if not (rt_equal_i32(loc_1406_, 76)) then
					loc_1400_ = loc_1406_;
				end
				rt_store_i32(loc_1402_, loc_1405_, 27520, loc_1400_)
				loc_1400_ = into_bits_i64(4294967295, 4294967295);
			end
			loc_1401_[1] = bit32_or(loc_1403_ + 16, 0);
			return loc_1400_, loc_1399_
		end), "i32,i64,i32->i64")
	end)(module_locals[82], module_locals[164], module_locals[3]);
	module_locals[103] = { nil };
	module_locals[103][1] = (function(loc_1407_, loc_1408_)
		return rt_function_type(--[[fn:__stdio_seek]](function(loc_1409_, loc_1410_, loc_1411_, loc_1412_)
			local loc_1413_, loc_1414_, loc_1415_
			loc_1413_ = buffer_read_i32(loc_1408_[1], loc_1409_, 56);
			loc_1415_ = loc_1408_;
			loc_1414_ = loc_1412_;
			loc_1414_ = loc_1407_[1](loc_1413_, loc_1410_, loc_1411_, loc_1414_)
			return loc_1414_, loc_1413_
		end), "i32,i64,i32->i64")
	end)(module_locals[102], module_locals[3]);
	module_locals[104] = { nil };
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[104][1] = (function(loc_1416_, loc_1417_, loc_1418_)
		return rt_function_type(--[[fn:writev]](function(loc_1419_, loc_1420_, loc_1421_, loc_1422_)
			local loc_1423_, loc_1424_, loc_1425_, loc_1426_, loc_1427_, loc_1428_, loc_1429_, loc_1430_, loc_1431_
			loc_1431_ = loc_1417_[1];
			loc_1425_ = loc_1417_;
			loc_1427_ = bit32_or(loc_1431_ - 16, 0);
			loc_1425_[1] = loc_1427_;
			loc_1431_ = -1;
			if rt_greater_than_s32(loc_1421_, -1) then
				loc_1423_ = loc_1421_;
				loc_1424_ = loc_1422_;
				loc_1426_ = loc_1418_;
				loc_1428_ = loc_1416_;
				loc_1429_ = loc_1420_;
				loc_1430_ = loc_1419_;
				rt_store_i32(loc_1426_, loc_1427_, 12, 0)
				loc_1424_ = loc_1428_[1](loc_1430_, loc_1429_, loc_1423_, bit32_or(loc_1427_ + 12, 0), loc_1424_)
				if rt_equal_i32(loc_1424_, 0) then
					loc_1424_ = buffer_read_i32(loc_1426_[1], loc_1427_, 12);
				else
					rt_store_i32(loc_1426_, 0, 27520, loc_1424_)
					loc_1424_ = -1;
				end
			else
				loc_1423_ = loc_1421_;
				loc_1424_ = loc_1420_;
				loc_1426_ = loc_1418_;
				loc_1428_ = loc_1416_;
				loc_1429_ = loc_1419_;
				loc_1430_ = loc_1431_;
				loc_1431_ = loc_1422_;
				rt_store_i32(loc_1426_, 0, 27520, 28)
				loc_1424_ = loc_1430_;
				loc_1423_ = loc_1431_;
			end
			loc_1425_[1] = bit32_or(loc_1427_ + 16, 0);
			return loc_1424_, loc_1423_
		end), "i32,i32,i32->i32")
	end)(module_locals[83], module_locals[164], module_locals[3]);
	module_locals[105] = { nil };
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[105][1] = (function(loc_1432_, loc_1433_, loc_1434_)
		return rt_function_type(--[[fn:__stdio_write]](function(loc_1435_, loc_1436_, loc_1437_, loc_1438_)
			local loc_1439_, loc_1440_, loc_1441_, loc_1442_, loc_1443_, loc_1444_, loc_1445_, loc_1446_, loc_1447_, loc_1448_, loc_1449_, loc_1450_, loc_1451_, loc_1452_, loc_1453_, loc_1454_, loc_1455_, loc_1456_
			loc_1456_ = loc_1433_[1];
			loc_1441_ = loc_1433_;
			loc_1443_ = bit32_or(loc_1456_ - 16, 0);
			rt_store_i32(loc_1434_, loc_1443_, 12, loc_1437_)
			loc_1442_ = loc_1434_;
			rt_store_i32(loc_1442_, loc_1443_, 8, loc_1436_)
			loc_1455_ = buffer_read_i32(loc_1442_[1], loc_1435_, 24);
			rt_store_i32(loc_1442_, loc_1443_, 0, loc_1455_)
			loc_1456_ = buffer_read_i32(loc_1442_[1], loc_1435_, 20);
			loc_1456_ = bit32_or(loc_1456_ - loc_1455_, 0);
			rt_store_i32(loc_1442_, loc_1443_, 4, loc_1456_)
			loc_1454_ = buffer_read_i32(loc_1442_[1], loc_1435_, 56);
			loc_1441_[1] = loc_1443_;
			loc_1455_ = loc_1438_;
			loc_1440_ = loc_1432_[1](loc_1454_, loc_1443_, 2, loc_1455_)
			loc_1447_ = 0;
			loc_1448_ = 2;
			loc_1449_ = bit32_or(loc_1456_ + loc_1437_, 0);
			if rt_equal_i32(loc_1440_, loc_1449_) then
				loc_1444_ = loc_1432_;
				loc_1445_ = loc_1435_;
				loc_1446_ = loc_1437_;
				loc_1447_ = 0;
			else
				loc_1444_ = loc_1432_;
				loc_1445_ = loc_1435_;
				loc_1446_ = loc_1437_;
				loc_1455_ = loc_1443_;
				loc_1456_ = loc_1449_;
				loc_1443_ = loc_1455_;
				loc_1449_ = loc_1455_;
				loc_1450_ = loc_1456_;
				repeat
					rt_yield_budget = rt_yield_budget - 1
					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
					loc_1456_ = loc_1447_;
					if rt_greater_than_s32(loc_1440_, -1) then
						loc_1447_ = loc_1439_;
						loc_1439_ = loc_1448_;
						loc_1451_ = loc_1450_;
						loc_1454_ = loc_1449_;
						loc_1455_ = loc_1440_;
						loc_1453_ = buffer_read_i32(loc_1442_[1], loc_1454_, 4);
						loc_1448_ = (rt_greater_than_u32(loc_1455_, loc_1453_) and 1 or 0);
						loc_1456_ = 8;
						loc_1452_ = 0;
						if rt_not_equal_i32(loc_1448_, 0) then
							loc_1440_ = loc_1454_;
						else
							loc_1440_ = loc_1454_;
							loc_1456_ = loc_1452_;
						end
						loc_1452_ = bit32_or(loc_1454_ + loc_1456_, 0);
						loc_1454_ = buffer_read_i32(loc_1442_[1], loc_1452_, 0);
						loc_1456_ = 0;
						if rt_not_equal_i32(loc_1448_, 0) then
							loc_1449_ = loc_1452_;
							loc_1450_ = loc_1455_;
						else
							loc_1449_ = loc_1452_;
							loc_1450_ = loc_1455_;
							loc_1453_ = loc_1456_;
						end
						loc_1453_ = bit32_or(loc_1455_ - loc_1453_, 0);
						rt_store_i32(loc_1442_, loc_1452_, 0, bit32_or(loc_1454_ + loc_1453_, 0))
						loc_1452_ = 12;
						loc_1454_ = 4;
						if not (rt_not_equal_i32(loc_1448_, 0)) then
							loc_1452_ = loc_1454_;
						end
						loc_1452_ = bit32_or(loc_1440_ + loc_1452_, 0);
						loc_1440_ = buffer_read_i32(loc_1442_[1], loc_1452_, 0);
						rt_store_i32(loc_1442_, loc_1452_, 0, bit32_or(loc_1440_ - loc_1453_, 0))
						loc_1440_ = buffer_read_i32(loc_1442_[1], loc_1445_, 56);
						loc_1448_ = bit32_or(loc_1439_ - loc_1448_, 0);
						loc_1440_ = loc_1444_[1](loc_1440_, loc_1449_, loc_1448_, loc_1447_)
						loc_1450_ = bit32_or(loc_1451_ - loc_1450_, 0);
						if rt_not_equal_i32(loc_1450_, loc_1440_) then
							loc_1451_ = 1;
							loc_1447_ = 65535;
						else
							loc_1451_ = 0;
							loc_1447_ = 1;
						end
					else
						loc_1453_ = loc_1440_;
						loc_1454_ = loc_1449_;
						loc_1455_ = loc_1450_;
						loc_1456_ = loc_1439_;
						loc_1439_ = loc_1448_;
						loc_1451_ = 0;
						loc_1447_ = 0;
						loc_1440_ = loc_1453_;
						loc_1449_ = loc_1454_;
						loc_1448_ = loc_1439_;
						loc_1450_ = loc_1455_;
						loc_1439_ = loc_1456_;
					end
				until loc_1451_ == 0
				if rt_not_equal_i32(loc_1447_, 0) then
					loc_1447_ = 0;
				else
					loc_1447_ = loc_1440_;
					rt_store_i32(loc_1442_, loc_1445_, 24, 0)
					rt_store_i64(loc_1442_, loc_1445_, 16, into_bits_i64(0, 0))
					loc_1447_ = buffer_read_i32(loc_1442_[1], loc_1445_, 0);
					rt_store_i32(loc_1442_, loc_1445_, 0, rt_or_i32(loc_1447_, 32))
					loc_1440_ = 0;
					if rt_equal_i32(loc_1448_, 2) then
						loc_1447_ = 1;
					else
						loc_1448_ = loc_1440_;
						loc_1449_ = buffer_read_i32(loc_1442_[1], loc_1449_, 4);
						loc_1447_ = 1;
						loc_1440_ = bit32_or(loc_1446_ - loc_1449_, 0);
					end
				end
			end
			if not (rt_not_equal_i32(loc_1447_, 0)) then
				loc_1447_ = loc_1440_;
				loc_1447_ = buffer_read_i32(loc_1442_[1], loc_1445_, 40);
				rt_store_i32(loc_1442_, loc_1445_, 24, loc_1447_)
				rt_store_i32(loc_1442_, loc_1445_, 20, loc_1447_)
				loc_1440_ = buffer_read_i32(loc_1442_[1], loc_1445_, 44);
				rt_store_i32(loc_1442_, loc_1445_, 16, bit32_or(loc_1447_ + loc_1440_, 0))
				loc_1440_ = loc_1446_;
			end
			loc_1441_[1] = bit32_or(loc_1443_ + 16, 0);
			return loc_1440_, loc_1439_
		end), "i32,i32,i32->i32")
	end)(module_locals[104], module_locals[164], module_locals[3]);
	module_locals[106] = { nil };
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[106][1] = (function(loc_1457_, loc_1458_, loc_1459_)
		return rt_function_type(--[[fn:readv]](function(loc_1460_, loc_1461_, loc_1462_, loc_1463_)
			local loc_1464_, loc_1465_, loc_1466_, loc_1467_, loc_1468_, loc_1469_, loc_1470_, loc_1471_, loc_1472_
			loc_1472_ = loc_1458_[1];
			loc_1466_ = loc_1458_;
			loc_1468_ = bit32_or(loc_1472_ - 16, 0);
			loc_1466_[1] = loc_1468_;
			loc_1472_ = -1;
			if rt_greater_than_s32(loc_1462_, -1) then
				loc_1464_ = loc_1462_;
				loc_1465_ = loc_1463_;
				loc_1467_ = loc_1459_;
				loc_1469_ = loc_1457_;
				loc_1470_ = loc_1461_;
				loc_1471_ = loc_1460_;
				loc_1465_ = loc_1469_[1](loc_1471_, loc_1470_, loc_1464_, bit32_or(loc_1468_ + 12, 0), loc_1465_)
				if rt_equal_i32(loc_1465_, 0) then
					loc_1465_ = buffer_read_i32(loc_1467_[1], loc_1468_, 12);
				else
					rt_store_i32(loc_1467_, 0, 27520, loc_1465_)
					loc_1465_ = -1;
				end
			else
				loc_1464_ = loc_1462_;
				loc_1465_ = loc_1461_;
				loc_1467_ = loc_1459_;
				loc_1469_ = loc_1457_;
				loc_1470_ = loc_1460_;
				loc_1471_ = loc_1472_;
				loc_1472_ = loc_1463_;
				rt_store_i32(loc_1467_, 0, 27520, 28)
				loc_1465_ = loc_1471_;
				loc_1464_ = loc_1472_;
			end
			loc_1466_[1] = bit32_or(loc_1468_ + 16, 0);
			return loc_1465_, loc_1464_
		end), "i32,i32,i32->i32")
	end)(module_locals[81], module_locals[164], module_locals[3]);
	module_locals[107] = { nil };
	module_locals[107][1] = (function(loc_1473_, loc_1474_, loc_1475_)
		return rt_function_type(--[[fn:read]](function(loc_1476_, loc_1477_, loc_1478_, loc_1479_)
			local loc_1480_, loc_1481_, loc_1482_, loc_1483_, loc_1484_, loc_1485_, loc_1486_, loc_1487_
			loc_1487_ = loc_1474_[1];
			loc_1482_ = loc_1474_;
			loc_1484_ = bit32_or(loc_1487_ - 16, 0);
			loc_1482_[1] = loc_1484_;
			rt_store_i32(loc_1475_, loc_1484_, 12, loc_1478_)
			loc_1483_ = loc_1475_;
			rt_store_i32(loc_1483_, loc_1484_, 8, loc_1477_)
			loc_1487_ = loc_1479_;
			loc_1481_ = loc_1473_[1](loc_1476_, bit32_or(loc_1484_ + 8, 0), 1, bit32_or(loc_1484_ + 4, 0), loc_1487_)
			if rt_equal_i32(loc_1481_, 0) then
				loc_1485_ = loc_1473_;
				loc_1481_ = buffer_read_i32(loc_1483_[1], loc_1484_, 4);
			else
				loc_1485_ = loc_1473_;
				loc_1487_ = loc_1481_;
				loc_1486_ = 0;
				loc_1481_ = 8;
				if not (rt_equal_i32(loc_1487_, 76)) then
					loc_1481_ = loc_1487_;
				end
				rt_store_i32(loc_1483_, loc_1486_, 27520, loc_1481_)
				loc_1481_ = -1;
			end
			loc_1482_[1] = bit32_or(loc_1484_ + 16, 0);
			return loc_1481_, loc_1480_
		end), "i32,i32,i32->i32")
	end)(module_locals[81], module_locals[164], module_locals[3]);
	module_locals[108] = { nil };
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[108][1] = (function(loc_1488_, loc_1489_, loc_1490_, loc_1491_)
		return rt_function_type(--[[fn:__stdio_read]](function(loc_1492_, loc_1493_, loc_1494_, loc_1495_)
			local loc_1496_, loc_1497_, loc_1498_, loc_1499_, loc_1500_, loc_1501_, loc_1502_, loc_1503_, loc_1504_, loc_1505_, loc_1506_, loc_1507_, loc_1508_
			loc_1508_ = loc_1490_[1];
			loc_1498_ = loc_1490_;
			loc_1500_ = bit32_or(loc_1508_ - 16, 0);
			loc_1498_[1] = loc_1500_;
			rt_store_i32(loc_1491_, loc_1500_, 0, loc_1493_)
			loc_1499_ = loc_1491_;
			loc_1496_ = buffer_read_i32(loc_1499_[1], loc_1492_, 44);
			rt_store_i32(loc_1499_, loc_1500_, 12, loc_1496_)
			loc_1505_ = buffer_read_i32(loc_1499_[1], loc_1492_, 40);
			rt_store_i32(loc_1499_, loc_1500_, 8, loc_1505_)
			loc_1508_ = bit32_or(loc_1494_ - (rt_not_equal_i32(loc_1496_, 0) and 1 or 0), 0);
			rt_store_i32(loc_1499_, loc_1500_, 4, loc_1508_)
			loc_1506_ = buffer_read_i32(loc_1499_[1], loc_1492_, 56);
			if rt_equal_i32(loc_1508_, 0) then
				loc_1497_ = loc_1494_;
				loc_1501_ = loc_1488_;
				loc_1503_ = loc_1492_;
				loc_1504_ = loc_1493_;
				loc_1507_ = loc_1495_;
				loc_1508_ = loc_1489_;
				loc_1502_ = loc_1508_;
				loc_1507_ = loc_1508_[1](loc_1506_, loc_1505_, loc_1496_, loc_1507_)
			else
				loc_1497_ = loc_1494_;
				loc_1501_ = loc_1505_;
				loc_1502_ = loc_1496_;
				loc_1503_ = loc_1492_;
				loc_1504_ = loc_1493_;
				loc_1505_ = loc_1489_;
				loc_1507_ = loc_1488_;
				loc_1508_ = loc_1495_;
				loc_1501_ = loc_1507_;
				loc_1502_ = loc_1505_;
				loc_1507_ = loc_1507_[1](loc_1506_, loc_1500_, 2, loc_1508_)
			end
			loc_1506_ = 0;
			if rt_greater_than_s32(loc_1507_, 0) then
				loc_1506_ = buffer_read_i32(loc_1499_[1], loc_1500_, 4);
				if rt_greater_than_u32(loc_1507_, loc_1506_) then
					loc_1505_ = buffer_read_i32(loc_1499_[1], loc_1503_, 40);
					rt_store_i32(loc_1499_, loc_1503_, 4, loc_1505_)
					rt_store_i32(loc_1499_, loc_1503_, 8, bit32_or(loc_1505_ + bit32_or(loc_1507_ - loc_1506_, 0), 0))
					loc_1506_ = buffer_read_i32(loc_1499_[1], loc_1503_, 44);
					if not (rt_equal_i32(loc_1506_, 0)) then
						rt_store_i32(loc_1499_, loc_1503_, 4, bit32_or(loc_1505_ + 1, 0))
						loc_1505_ = rt_load_i32_from_u8(loc_1499_, loc_1505_, 0);
						rt_store_i32_into_i8(loc_1499_, bit32_or(bit32_or(loc_1504_ + loc_1497_, 0) + -1, 0), 0, loc_1505_)
					end
				else
					loc_1505_ = loc_1504_;
					loc_1504_ = loc_1497_;
					loc_1503_, loc_1506_ = loc_1506_, loc_1503_;
					loc_1497_ = loc_1507_;
				end
			else
				loc_1505_ = loc_1497_;
				loc_1497_ = loc_1507_;
				loc_1507_ = loc_1504_;
				loc_1505_ = buffer_read_i32(loc_1499_[1], loc_1503_, 0);
				loc_1507_ = 32;
				loc_1504_ = 16;
				if rt_not_equal_i32(loc_1497_, 0) then
					loc_1497_ = loc_1506_;
					loc_1506_ = loc_1505_;
					loc_1505_ = loc_1503_;
				else
					loc_1497_ = loc_1506_;
					loc_1506_ = loc_1505_;
					loc_1505_ = loc_1503_;
					loc_1507_ = loc_1504_;
				end
				rt_store_i32(loc_1499_, loc_1505_, 0, rt_or_i32(loc_1506_, loc_1507_))
			end
			loc_1498_[1] = bit32_or(loc_1500_ + 16, 0);
			return loc_1497_, loc_1496_
		end), "i32,i32,i32->i32")
	end)(module_locals[106], module_locals[107], module_locals[164], module_locals[3]);
	module_locals[109] = { nil };
	module_locals[109][1] = (function(loc_1509_, loc_1510_)
		return rt_function_type(--[[fn:__stdio_close]](function(loc_1511_, loc_1512_)
			local loc_1513_, loc_1514_, loc_1515_
			loc_1513_ = buffer_read_i32(loc_1510_[1], loc_1511_, 56);
			loc_1515_ = loc_1510_;
			loc_1514_ = loc_1512_;
			loc_1514_ = loc_1509_[1](loc_1513_, loc_1514_)
			return loc_1514_, loc_1513_
		end), "i32->i32")
	end)(module_locals[98], module_locals[3]);
	module_locals[110] = { nil };
	module_locals[119] = { nil };
	module_locals[136] = { nil };
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[110][1] = (function(loc_1516_, loc_1517_, loc_1518_, loc_1519_, loc_1520_, loc_1521_, loc_1522_, loc_1523_)
		return rt_function_type(--[[fn:__fdopen]](function(loc_1524_, loc_1525_, loc_1526_)
			local loc_1527_, loc_1528_, loc_1529_, loc_1530_, loc_1531_, loc_1532_, loc_1533_, loc_1534_, loc_1535_, loc_1536_, loc_1537_, loc_1538_, loc_1539_, loc_1540_, loc_1541_, loc_1542_, loc_1543_
			loc_1541_ = rt_load_i32_from_s8(loc_1523_, loc_1525_, 0);
			loc_1530_ = loc_1523_;
			loc_1543_ = loc_1522_[1];
			loc_1529_ = loc_1522_;
			loc_1531_ = bit32_or(loc_1543_ - 32, 0);
			loc_1529_[1] = loc_1531_;
			loc_1543_ = loc_1526_;
			loc_1542_ = loc_1519_[1](1229, loc_1541_, 4, loc_1543_)
			if rt_not_equal_i32(loc_1542_, 0) then
				loc_1532_ = loc_1516_;
				loc_1533_ = loc_1517_;
				loc_1534_ = loc_1524_;
				loc_1535_ = loc_1519_;
				loc_1536_ = loc_1520_;
				loc_1537_ = loc_1521_;
				loc_1538_ = loc_1518_;
				loc_1540_ = loc_1525_;
				loc_1527_ = loc_1537_[1](1144, loc_1543_)
				if rt_not_equal_i32(loc_1527_, 0) then
					loc_1539_ = 0;
					if not (rt_equal_i32(112, 0)) then
						rt_memory_fill(loc_1530_, loc_1527_, 0, 112)
					end
					loc_1543_ = loc_1536_[1](loc_1540_, 43, loc_1543_)
					if not (rt_not_equal_i32(loc_1543_, 0)) then
						loc_1543_ = loc_1539_;
						loc_1539_ = 8;
						loc_1543_ = 4;
						if rt_equal_i32(loc_1541_, 114) then
							loc_1528_ = loc_1527_;
						else
							loc_1528_ = loc_1527_;
							loc_1539_ = loc_1543_;
						end
						rt_store_i32(loc_1530_, loc_1528_, 0, loc_1539_)
					end
					loc_1542_ = loc_1536_[1](loc_1540_, 101, loc_1542_)
					if not (rt_equal_i32(loc_1542_, 0)) then
						loc_1528_, loc_1532_ = loc_1532_, loc_1528_;
						loc_1532_, loc_1541_ = loc_1541_, loc_1532_;
						loc_1532_ = loc_1528_;
						rt_store_i32(loc_1530_, loc_1531_, 16, 1)
						loc_1541_ = loc_1528_[1](loc_1534_, 2, bit32_or(loc_1531_ + 16, 0), loc_1541_)
						loc_1541_ = rt_load_i32_from_u8(loc_1530_, loc_1540_, 0);
					end
					if not (rt_not_equal_i32(rt_and_i32(loc_1541_, 255), 97)) then
						loc_1541_ = loc_1528_;
						loc_1540_ = loc_1532_[1](loc_1534_, 3, 0, loc_1541_)
						if not (rt_not_equal_i32(rt_and_i32(loc_1540_, 1), 0)) then
							loc_1541_ = loc_1540_;
							loc_1540_ = loc_1528_;
							loc_1528_ = loc_1532_;
							loc_1532_ = loc_1528_;
							rt_store_i32(loc_1530_, loc_1531_, 0, rt_or_i32(loc_1541_, 1))
							loc_1540_ = loc_1528_[1](loc_1534_, 4, loc_1531_, loc_1540_)
						end
						loc_1539_ = rt_or_i32(loc_1539_, 128);
						rt_store_i32(loc_1530_, loc_1527_, 0, loc_1539_)
					end
					rt_store_i32(loc_1530_, loc_1527_, 64, -1)
					rt_store_i32(loc_1530_, loc_1527_, 44, 1024)
					rt_store_i32(loc_1530_, loc_1527_, 56, loc_1534_)
					rt_store_i32(loc_1530_, loc_1527_, 40, bit32_or(loc_1527_ + 120, 0))
					if not (rt_not_equal_i32(rt_and_i32(loc_1539_, 8), 0)) then
						loc_1534_ = loc_1533_[1](loc_1534_, loc_1528_)
						if not (rt_equal_i32(loc_1534_, 0)) then
							rt_store_i32(loc_1530_, loc_1527_, 64, 10)
						end
					end
					loc_1534_ = loc_1538_;
					rt_store_i32(loc_1530_, loc_1527_, 36, 7)
					rt_store_i32(loc_1530_, loc_1527_, 32, 8)
					rt_store_i32(loc_1530_, loc_1527_, 28, 9)
					rt_store_i32(loc_1530_, loc_1527_, 12, 10)
					loc_1528_ = loc_1538_[1](loc_1527_, loc_1528_)
				else
					loc_1539_ = loc_1527_;
					loc_1542_ = loc_1534_;
					loc_1540_, loc_1541_ = loc_1541_, loc_1540_;
					loc_1534_ = loc_1538_;
					loc_1528_ = 0;
					loc_1527_ = loc_1543_;
				end
			else
				loc_1532_ = loc_1516_;
				loc_1533_ = loc_1517_;
				loc_1535_ = loc_1519_;
				loc_1536_ = loc_1520_;
				loc_1537_ = loc_1521_;
				loc_1538_ = loc_1518_;
				loc_1540_ = loc_1541_;
				loc_1541_ = loc_1525_;
				loc_1542_ = loc_1524_;
				loc_1534_ = loc_1538_;
				rt_store_i32(loc_1530_, 0, 27520, 28)
				loc_1528_ = 0;
				loc_1527_ = loc_1543_;
			end
			loc_1529_[1] = bit32_or(loc_1531_ + 32, 0);
			return loc_1528_, loc_1527_
		end), "i32,i32->i32")
	end)(module_locals[100], module_locals[101], module_locals[119], module_locals[136], module_locals[138], module_locals[156], module_locals[164], module_locals[3]);
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[111][1] = (function(loc_1544_, loc_1545_, loc_1546_, loc_1547_, loc_1548_, loc_1549_)
		return rt_function_type(--[[fn:fopen]](function(loc_1550_, loc_1551_, loc_1552_)
			local loc_1553_, loc_1554_, loc_1555_, loc_1556_, loc_1557_, loc_1558_, loc_1559_, loc_1560_, loc_1561_, loc_1562_
			loc_1561_ = rt_load_i32_from_s8(loc_1549_, loc_1551_, 0);
			loc_1555_ = loc_1549_;
			loc_1562_ = loc_1552_;
			loc_1562_ = loc_1548_[1](1229, loc_1561_, 4, loc_1562_)
			if rt_not_equal_i32(loc_1562_, 0) then
				loc_1553_ = loc_1550_;
				loc_1556_ = loc_1544_;
				loc_1557_ = loc_1545_;
				loc_1558_ = loc_1546_;
				loc_1559_ = loc_1547_;
				loc_1560_ = loc_1548_;
				loc_1562_ = loc_1551_;
				loc_1554_ = loc_1556_[1](loc_1562_, loc_1561_)
				loc_1561_ = loc_1558_[1](loc_1553_, loc_1554_, loc_1561_)
				loc_1554_ = 0;
				if not (rt_less_than_s32(loc_1561_, 0)) then
					loc_1554_ = loc_1553_;
					loc_1554_ = loc_1559_[1](loc_1561_, loc_1562_, loc_1554_)
					if rt_not_equal_i32(loc_1554_, 0) then
						loc_1562_ = loc_1561_;
					else
						loc_1562_ = loc_1561_;
						loc_1561_ = loc_1554_;
						loc_1554_ = loc_1557_;
						loc_1557_ = loc_1554_;
						loc_1561_ = loc_1553_;
						loc_1562_ = loc_1554_[1](loc_1562_, loc_1561_)
						loc_1554_ = 0;
					end
				end
			else
				loc_1554_ = loc_1551_;
				loc_1556_ = loc_1544_;
				loc_1557_ = loc_1545_;
				loc_1558_ = loc_1546_;
				loc_1559_ = loc_1547_;
				loc_1560_ = loc_1548_;
				loc_1562_ = loc_1550_;
				rt_store_i32(loc_1555_, 0, 27520, 28)
				loc_1554_ = 0;
				loc_1553_ = loc_1561_;
			end
			return loc_1554_, loc_1553_
		end), "i32,i32->i32")
	end)(module_locals[92], module_locals[98], module_locals[99], module_locals[110], module_locals[136], module_locals[3]);
	module_locals[112][1] = (function(loc_1563_, loc_1564_, loc_1565_)
		return rt_function_type(--[[fn:__stdio_exit]](function(loc_1566_)
			local loc_1567_, loc_1568_, loc_1569_, loc_1570_, loc_1571_, loc_1572_, loc_1573_, loc_1574_
			loc_1568_ = loc_1564_;
			loc_1569_ = loc_1565_;
			loc_1574_ = loc_1566_;
			loc_1574_ = loc_1563_[1](loc_1574_)
			loc_1574_ = buffer_read_i32(loc_1569_[1], loc_1574_, 0);
			if rt_equal_i32(loc_1574_, 0) then
				loc_1570_ = loc_1563_;
			else
				loc_1570_ = loc_1563_;
				repeat
					rt_yield_budget = rt_yield_budget - 1
					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
					loc_1572_ = buffer_read_i32(loc_1569_[1], loc_1574_, 20);
					loc_1573_ = buffer_read_i32(loc_1569_[1], loc_1574_, 24);
					if not (rt_equal_i32(loc_1572_, loc_1573_)) then
						loc_1573_ = buffer_read_i32(loc_1569_[1], loc_1574_, 32);
						loc_1572_ = rt_table_get_function(loc_1568_, loc_1573_, "i32,i32,i32->i32");
						loc_1573_ = loc_1567_;
						loc_1573_ = loc_1572_(loc_1574_, 0, 0, loc_1573_)
					end
					loc_1573_ = buffer_read_i32(loc_1569_[1], loc_1574_, 4);
					loc_1572_ = buffer_read_i32(loc_1569_[1], loc_1574_, 8);
					if not (rt_equal_i32(loc_1573_, loc_1572_)) then
						loc_1571_ = loc_1567_;
						loc_1567_ = buffer_read_i32(loc_1569_[1], loc_1574_, 36);
						loc_1567_ = rt_table_get_function(loc_1568_, loc_1567_, "i32,i64,i32->i64");
						loc_1573_ = loc_1567_(loc_1574_, rt_extend_s32_to_i64(bit32_or(loc_1573_ - loc_1572_, 0)), 1, loc_1571_)
					end
					loc_1573_ = buffer_read_i32(loc_1569_[1], loc_1574_, 52);
					loc_1574_ = loc_1573_;
				until loc_1573_ == 0
			end
			loc_1574_ = buffer_read_i32(loc_1569_[1], 0, 27548);
			if not (rt_equal_i32(loc_1574_, 0)) then
				loc_1572_ = buffer_read_i32(loc_1569_[1], loc_1574_, 20);
				loc_1573_ = buffer_read_i32(loc_1569_[1], loc_1574_, 24);
				if not (rt_equal_i32(loc_1572_, loc_1573_)) then
					loc_1573_ = buffer_read_i32(loc_1569_[1], loc_1574_, 32);
					loc_1572_ = rt_table_get_function(loc_1568_, loc_1573_, "i32,i32,i32->i32");
					loc_1573_ = loc_1567_;
					loc_1573_ = loc_1572_(loc_1574_, 0, 0, loc_1573_)
				end
				loc_1573_ = buffer_read_i32(loc_1569_[1], loc_1574_, 4);
				loc_1572_ = buffer_read_i32(loc_1569_[1], loc_1574_, 8);
				if not (rt_equal_i32(loc_1573_, loc_1572_)) then
					loc_1571_ = loc_1567_;
					loc_1567_ = buffer_read_i32(loc_1569_[1], loc_1574_, 36);
					loc_1567_ = rt_table_get_function(loc_1568_, loc_1567_, "i32,i64,i32->i64");
					loc_1574_ = loc_1567_(loc_1574_, rt_extend_s32_to_i64(bit32_or(loc_1573_ - loc_1572_, 0)), 1, loc_1571_)
				end
			end
			loc_1574_ = buffer_read_i32(loc_1569_[1], 0, 10792);
			if not (rt_equal_i32(loc_1574_, 0)) then
				loc_1572_ = buffer_read_i32(loc_1569_[1], loc_1574_, 20);
				loc_1573_ = buffer_read_i32(loc_1569_[1], loc_1574_, 24);
				if not (rt_equal_i32(loc_1572_, loc_1573_)) then
					loc_1573_ = buffer_read_i32(loc_1569_[1], loc_1574_, 32);
					loc_1572_ = rt_table_get_function(loc_1568_, loc_1573_, "i32,i32,i32->i32");
					loc_1573_ = loc_1567_;
					loc_1573_ = loc_1572_(loc_1574_, 0, 0, loc_1573_)
				end
				loc_1573_ = buffer_read_i32(loc_1569_[1], loc_1574_, 4);
				loc_1572_ = buffer_read_i32(loc_1569_[1], loc_1574_, 8);
				if not (rt_equal_i32(loc_1573_, loc_1572_)) then
					loc_1571_ = loc_1567_;
					loc_1567_ = buffer_read_i32(loc_1569_[1], loc_1574_, 36);
					loc_1567_ = rt_table_get_function(loc_1568_, loc_1567_, "i32,i64,i32->i64");
					loc_1574_ = loc_1567_(loc_1574_, rt_extend_s32_to_i64(bit32_or(loc_1573_ - loc_1572_, 0)), 1, loc_1571_)
				end
			end
			loc_1571_ = buffer_read_i32(loc_1569_[1], 0, 10912);
			if not (rt_equal_i32(loc_1571_, 0)) then
				loc_1573_ = buffer_read_i32(loc_1569_[1], loc_1571_, 20);
				loc_1574_ = buffer_read_i32(loc_1569_[1], loc_1571_, 24);
				if not (rt_equal_i32(loc_1573_, loc_1574_)) then
					loc_1574_ = buffer_read_i32(loc_1569_[1], loc_1571_, 32);
					loc_1573_ = rt_table_get_function(loc_1568_, loc_1574_, "i32,i32,i32->i32");
					loc_1574_ = loc_1567_;
					loc_1574_ = loc_1573_(loc_1571_, 0, 0, loc_1574_)
				end
				loc_1572_ = buffer_read_i32(loc_1569_[1], loc_1571_, 4);
				loc_1573_ = buffer_read_i32(loc_1569_[1], loc_1571_, 8);
				if not (rt_equal_i32(loc_1572_, loc_1573_)) then
					loc_1574_ = buffer_read_i32(loc_1569_[1], loc_1571_, 36);
					loc_1574_ = rt_table_get_function(loc_1568_, loc_1574_, "i32,i64,i32->i64");
					loc_1573_ = loc_1574_(loc_1571_, rt_extend_s32_to_i64(bit32_or(loc_1572_ - loc_1573_, 0)), 1, loc_1567_)
				end
			end
			return loc_1567_
		end), "->")
	end)(module_locals[117], module_locals[162], module_locals[3]);
	module_locals[113] = { nil };
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[113][1] = (function(loc_1575_, loc_1576_)
		return rt_function_type(--[[fn:__toread]](function(loc_1577_, loc_1578_)
			local loc_1579_, loc_1580_, loc_1581_, loc_1582_, loc_1583_, loc_1584_, loc_1585_
			loc_1585_ = buffer_read_i32(loc_1576_[1], loc_1577_, 60);
			loc_1582_ = loc_1576_;
			rt_store_i32(loc_1582_, loc_1577_, 60, rt_or_i32(bit32_or(loc_1585_ + -1, 0), loc_1585_))
			loc_1584_ = buffer_read_i32(loc_1582_[1], loc_1577_, 20);
			loc_1585_ = buffer_read_i32(loc_1582_[1], loc_1577_, 24);
			if rt_equal_i32(loc_1584_, loc_1585_) then
				loc_1579_ = loc_1578_;
				loc_1581_ = loc_1575_;
				loc_1584_ = loc_1577_;
			else
				loc_1579_ = loc_1578_;
				loc_1581_ = loc_1575_;
				loc_1584_ = loc_1577_;
				loc_1585_ = buffer_read_i32(loc_1582_[1], loc_1584_, 32);
				loc_1583_ = rt_table_get_function(loc_1581_, loc_1585_, "i32,i32,i32->i32");
				loc_1585_ = loc_1579_;
				loc_1585_ = loc_1583_(loc_1584_, 0, 0, loc_1585_)
			end
			rt_store_i32(loc_1582_, loc_1584_, 24, 0)
			rt_store_i64(loc_1582_, loc_1584_, 16, into_bits_i64(0, 0))
			loc_1580_ = buffer_read_i32(loc_1582_[1], loc_1584_, 0);
			if rt_equal_i32(rt_and_i32(loc_1580_, 4), 0) then
				loc_1585_ = buffer_read_i32(loc_1582_[1], loc_1584_, 40);
				loc_1583_ = buffer_read_i32(loc_1582_[1], loc_1584_, 44);
				loc_1583_ = bit32_or(loc_1585_ + loc_1583_, 0);
				rt_store_i32(loc_1582_, loc_1584_, 8, loc_1583_)
				rt_store_i32(loc_1582_, loc_1584_, 4, loc_1583_)
				loc_1580_ = rt_shift_right_s32(rt_shift_left_i32(loc_1580_, 27), 31);
			else
				rt_store_i32(loc_1582_, loc_1584_, 0, rt_or_i32(loc_1580_, 32))
				loc_1580_ = -1;
			end
			return loc_1580_, loc_1579_
		end), "i32->i32")
	end)(module_locals[162], module_locals[3]);
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[114][1] = (function(loc_1586_, loc_1587_, loc_1588_)
		return rt_function_type(--[[fn:fread]](function(loc_1589_, loc_1590_, loc_1591_, loc_1592_, loc_1593_)
			local loc_1594_, loc_1595_, loc_1596_, loc_1597_, loc_1598_, loc_1599_, loc_1600_, loc_1601_, loc_1602_, loc_1603_, loc_1604_, loc_1605_, loc_1606_
			loc_1606_ = buffer_read_i32(loc_1588_[1], loc_1592_, 60);
			loc_1597_ = loc_1588_;
			rt_store_i32(loc_1597_, loc_1592_, 60, rt_or_i32(bit32_or(loc_1606_ + -1, 0), loc_1606_))
			loc_1595_ = buffer_read_i32(loc_1597_[1], loc_1592_, 4);
			loc_1605_ = buffer_read_i32(loc_1597_[1], loc_1592_, 8);
			loc_1600_ = 0;
			loc_1606_ = rt_multiply_i32(loc_1591_, loc_1590_);
			if rt_not_equal_i32(loc_1595_, loc_1605_) then
				loc_1594_ = loc_1593_;
				loc_1596_ = loc_1587_;
				loc_1598_ = loc_1586_;
				loc_1599_ = loc_1591_;
				loc_1601_ = loc_1590_;
				loc_1602_ = loc_1592_;
				loc_1603_ = loc_1589_;
				loc_1605_ = bit32_or(loc_1605_ - loc_1595_, 0);
				if rt_less_than_u32(loc_1605_, loc_1606_) then
					loc_1604_ = loc_1606_;
				else
					loc_1604_ = loc_1606_;
					loc_1605_ = loc_1606_;
				end
				if not (rt_equal_i32(loc_1605_, 0)) then
					rt_memory_copy(loc_1597_, loc_1603_, loc_1597_, loc_1595_, loc_1605_)
				end
				rt_store_i32(loc_1597_, loc_1602_, 4, bit32_or(loc_1595_ + loc_1605_, 0))
				loc_1595_ = bit32_or(loc_1603_ + loc_1605_, 0);
				loc_1603_ = bit32_or(loc_1604_ - loc_1605_, 0);
			else
				loc_1594_ = loc_1593_;
				loc_1596_ = loc_1587_;
				loc_1598_ = loc_1586_;
				loc_1599_ = loc_1591_;
				loc_1601_ = loc_1590_;
				loc_1602_ = loc_1592_;
				loc_1603_ = loc_1589_;
				loc_1604_ = loc_1605_;
				loc_1605_ = loc_1595_;
				loc_1595_ = loc_1603_;
				loc_1603_ = loc_1606_;
				loc_1604_ = loc_1606_;
			end
			loc_1605_ = 0;
			if not (rt_not_equal_i32(loc_1601_, 0)) then
				loc_1599_ = loc_1605_;
			end
			if rt_equal_i32(loc_1603_, 0) then
				loc_1600_ = 0;
			else
				loc_1605_ = loc_1604_;
				loc_1604_ = loc_1601_;
				loc_1601_ = loc_1600_;
				loc_1600_ = loc_1602_;
				loc_1602_ = loc_1605_;
				repeat
					rt_yield_budget = rt_yield_budget - 1
					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
					loc_1605_ = loc_1601_;
					loc_1605_ = loc_1594_;
					loc_1605_ = loc_1598_[1](loc_1600_, loc_1605_)
					if rt_not_equal_i32(loc_1605_, 0) then
						loc_1605_ = 0;
						loc_1601_ = 2;
					else
						loc_1605_ = loc_1603_;
						loc_1603_ = buffer_read_i32(loc_1597_[1], loc_1600_, 28);
						loc_1601_ = rt_table_get_function(loc_1596_, loc_1603_, "i32,i32,i32->i32");
						loc_1603_ = loc_1594_;
						loc_1603_ = loc_1601_(loc_1600_, loc_1595_, loc_1605_, loc_1603_)
						if rt_not_equal_i32(loc_1603_, 0) then
							loc_1601_ = loc_1595_;
							loc_1595_ = bit32_or(loc_1601_ + loc_1603_, 0);
							loc_1603_ = bit32_or(loc_1605_ - loc_1603_, 0);
							if rt_not_equal_i32(loc_1603_, 0) then
								loc_1605_ = 1;
								loc_1601_ = 65535;
							else
								loc_1605_ = 0;
								loc_1601_ = 1;
							end
						else
							loc_1603_, loc_1605_ = loc_1605_, loc_1603_;
							loc_1605_ = 0;
							loc_1601_ = 0;
						end
					end
				until loc_1605_ == 0
				if (loc_1601_) >= 0 and (loc_1601_) < 2 then
					if (loc_1601_) < 1 then
						loc_1601_ = 0;
					else
						loc_1601_ = 1;
					end
				else
					loc_1601_ = 0;
				end
				if rt_not_equal_i32(loc_1601_, 0) then
					loc_1600_ = 0;
				else
					loc_1601_ = loc_1595_;
					loc_1600_ = 1;
					loc_1604_ = rt_divide_u32(bit32_or(loc_1602_ - loc_1603_, 0), loc_1604_);
					loc_1595_ = loc_1604_;
				end
			end
			if not (rt_not_equal_i32(loc_1600_, 0)) then
				loc_1595_ = loc_1599_;
			end
			return loc_1595_, loc_1594_
		end), "i32,i32,i32,i32->i32")
	end)(module_locals[113], module_locals[162], module_locals[3]);
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[115][1] = (function(loc_1607_, loc_1608_)
		return rt_function_type(--[[fn:fseek]](function(loc_1609_, loc_1610_, loc_1611_, loc_1612_)
			local loc_1613_, loc_1614_, loc_1615_, loc_1616_, loc_1617_, loc_1618_, loc_1619_, loc_1620_
			if rt_less_than_u32(loc_1611_, 3) then
				loc_1613_ = loc_1612_;
				loc_1614_ = loc_1609_;
				loc_1615_ = loc_1607_;
				loc_1616_ = loc_1608_;
				loc_1617_ = loc_1611_;
				loc_1620_ = loc_1610_;
				loc_1618_ = rt_extend_s32_to_i64(loc_1620_);
				if not (rt_not_equal_i32(loc_1617_, 1)) then
					loc_1620_ = buffer_read_i32(loc_1616_[1], loc_1614_, 8);
					if not (rt_equal_i32(loc_1620_, 0)) then
						loc_1619_ = buffer_read_i32(loc_1616_[1], loc_1614_, 4);
						loc_1618_ = rt_subtract_i64(loc_1618_, rt_extend_s32_to_i64(bit32_or(loc_1620_ - loc_1619_, 0)));
					end
				end
				loc_1620_ = buffer_read_i32(loc_1616_[1], loc_1614_, 20);
				loc_1619_ = buffer_read_i32(loc_1616_[1], loc_1614_, 24);
				if rt_equal_i32(loc_1620_, loc_1619_) then
					loc_1619_ = 0;
				else
					loc_1619_ = loc_1613_;
					loc_1613_ = buffer_read_i32(loc_1616_[1], loc_1614_, 32);
					loc_1613_ = rt_table_get_function(loc_1615_, loc_1613_, "i32,i32,i32->i32");
					loc_1619_ = loc_1613_(loc_1614_, 0, 0, loc_1619_)
					loc_1619_ = buffer_read_i32(loc_1616_[1], loc_1614_, 20);
					if rt_not_equal_i32(loc_1619_, 0) then
						loc_1619_ = 0;
					else
						loc_1619_ = loc_1614_;
						loc_1619_ = 1;
						loc_1614_ = -1;
					end
				end
				if not (rt_not_equal_i32(loc_1619_, 0)) then
					rt_store_i32(loc_1616_, loc_1614_, 24, 0)
					rt_store_i64(loc_1616_, loc_1614_, 16, into_bits_i64(0, 0))
					loc_1619_ = buffer_read_i32(loc_1616_[1], loc_1614_, 36);
					loc_1619_ = rt_table_get_function(loc_1615_, loc_1619_, "i32,i64,i32->i64");
					loc_1618_ = loc_1619_(loc_1614_, loc_1618_, loc_1617_, loc_1613_)
					if rt_greater_than_equal_s64(loc_1618_, into_bits_i64(0, 0)) then
						loc_1617_ = loc_1614_;
						rt_store_i64(loc_1616_, loc_1617_, 4, into_bits_i64(0, 0))
						loc_1618_ = buffer_read_i32(loc_1616_[1], loc_1617_, 0);
						rt_store_i32(loc_1616_, loc_1617_, 0, rt_and_i32(loc_1618_, -17))
						loc_1614_ = 0;
					else
						loc_1618_ = loc_1614_;
						loc_1614_ = -1;
					end
				end
			else
				loc_1613_ = loc_1612_;
				loc_1615_ = loc_1607_;
				loc_1616_ = loc_1608_;
				loc_1618_ = loc_1611_;
				loc_1619_ = loc_1610_;
				loc_1620_ = loc_1609_;
				rt_store_i32(loc_1616_, 0, 27520, 28)
				loc_1614_ = -1;
			end
			return loc_1614_, loc_1613_
		end), "i32,i32,i32->i32")
	end)(module_locals[162], module_locals[3]);
	module_locals[116][1] = (function(loc_1621_, loc_1622_)
		return rt_function_type(--[[fn:ftell]](function(loc_1623_, loc_1624_)
			local loc_1625_, loc_1626_, loc_1627_, loc_1628_, loc_1629_, loc_1630_, loc_1631_, loc_1632_, loc_1633_
			loc_1630_ = buffer_read_i32(loc_1622_[1], loc_1623_, 36);
			loc_1628_ = loc_1622_;
			loc_1633_ = rt_load_i32_from_u8(loc_1628_, loc_1623_, 0);
			loc_1629_ = 1;
			if rt_equal_i32(rt_and_i32(loc_1633_, 128), 0) then
				loc_1626_ = loc_1623_;
				loc_1627_ = loc_1621_;
				loc_1632_ = loc_1624_;
			else
				loc_1626_ = loc_1623_;
				loc_1627_ = loc_1621_;
				loc_1632_ = loc_1624_;
				loc_1633_ = loc_1629_;
				loc_1633_ = buffer_read_i32(loc_1628_[1], loc_1626_, 20);
				loc_1625_ = buffer_read_i32(loc_1628_[1], loc_1626_, 24);
				loc_1629_ = 1;
				loc_1631_ = 2;
				if not (rt_equal_i32(loc_1633_, loc_1625_)) then
					loc_1629_ = loc_1631_;
				end
			end
			loc_1631_ = rt_table_get_function(loc_1627_, loc_1630_, "i32,i64,i32->i64");
			loc_1629_ = loc_1631_(loc_1626_, into_bits_i64(0, 0), loc_1629_, loc_1632_)
			if rt_less_than_s64(loc_1629_, into_bits_i64(0, 0)) then
				loc_1630_ = 0;
			else
				loc_1632_ = buffer_read_i32(loc_1628_[1], loc_1626_, 8);
				if rt_equal_i32(loc_1632_, 0) then
					loc_1631_ = buffer_read_i32(loc_1628_[1], loc_1626_, 24);
					if rt_equal_i32(loc_1631_, 0) then
						loc_1632_ = 1;
					else
						loc_1632_ = loc_1630_;
						loc_1632_ = 0;
						loc_1630_ = 20;
					end
				else
					loc_1631_ = loc_1632_;
					loc_1632_ = loc_1630_;
					loc_1632_ = 0;
					loc_1630_ = 4;
				end
				if not (rt_not_equal_i32(loc_1632_, 0)) then
					loc_1630_ = buffer_read_i32(loc_1628_[1], bit32_or(loc_1626_ + loc_1630_, 0), 0);
					loc_1629_ = rt_add_i64(loc_1629_, rt_extend_s32_to_i64(bit32_or(loc_1630_ - loc_1631_, 0)));
				end
				if rt_less_than_s64(loc_1629_, into_bits_i64(2147483648, 0)) then
					loc_1630_ = 0;
				else
					loc_1630_ = loc_1626_;
					rt_store_i32(loc_1628_, 0, 27520, 61)
					loc_1630_ = 1;
					loc_1626_ = -1;
				end
			end
			if not (rt_not_equal_i32(loc_1630_, 0)) then
				loc_1626_ = rt_narrow_i64(loc_1629_);
			end
			return loc_1626_, loc_1625_
		end), "i32->i32")
	end)(module_locals[162], module_locals[3]);
	module_locals[117][1] = rt_function_type(--[[fn:__ofl_lock]](function(loc_1634_)
		local loc_1635_
		loc_1635_ = loc_1634_;
		return 27552, loc_1635_
	end), "->i32");
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[118][1] = rt_function_type(--[[fn:__ofl_unlock]](function(loc_1636_)
		local loc_1637_
		loc_1637_ = loc_1636_;
		return loc_1637_
	end), "->");
	module_locals[119][1] = (function(loc_1638_, loc_1639_, loc_1640_)
		return rt_function_type(--[[fn:__ofl_add]](function(loc_1641_, loc_1642_)
			local loc_1643_, loc_1644_, loc_1645_, loc_1646_, loc_1647_, loc_1648_, loc_1649_
			loc_1645_ = loc_1640_;
			loc_1649_ = loc_1642_;
			loc_1647_ = loc_1638_[1](loc_1649_)
			loc_1649_ = buffer_read_i32(loc_1645_[1], loc_1647_, 0);
			rt_store_i32(loc_1645_, loc_1641_, 52, loc_1649_)
			if rt_equal_i32(loc_1649_, 0) then
				loc_1644_ = loc_1641_;
				loc_1646_ = loc_1639_;
				loc_1648_ = loc_1638_;
			else
				loc_1644_ = loc_1641_;
				loc_1646_ = loc_1639_;
				loc_1648_ = loc_1638_;
				rt_store_i32(loc_1645_, loc_1649_, 48, loc_1644_)
			end
			rt_store_i32(loc_1645_, loc_1647_, 0, loc_1644_)
			loc_1646_[1](loc_1643_)
			return loc_1644_, loc_1643_
		end), "i32->i32")
	end)(module_locals[117], module_locals[118], module_locals[3]);
	module_locals[150] = { nil };
	module_locals[120][1] = (function(loc_1650_, loc_1651_, loc_1652_)
		return rt_function_type(--[[fn:printf]](function(loc_1653_, loc_1654_, loc_1655_)
			local loc_1656_, loc_1657_, loc_1658_, loc_1659_, loc_1660_
			loc_1660_ = loc_1651_[1];
			loc_1658_ = loc_1651_;
			loc_1660_ = bit32_or(loc_1660_ - 16, 0);
			loc_1658_[1] = loc_1660_;
			rt_store_i32(loc_1652_, loc_1660_, 12, loc_1654_)
			loc_1659_ = loc_1652_;
			loc_1657_ = loc_1655_;
			loc_1657_ = loc_1650_[1](10680, loc_1653_, loc_1654_, loc_1657_)
			loc_1658_[1] = bit32_or(loc_1660_ + 16, 0);
			return loc_1657_, loc_1656_
		end), "i32,i32->i32")
	end)(module_locals[150], module_locals[164], module_locals[3]);
	module_locals[121] = { nil };
	module_locals[121][1] = (function(loc_1661_)
		return rt_function_type(--[[fn:__towrite]](function(loc_1662_, loc_1663_)
			local loc_1664_, loc_1665_, loc_1666_, loc_1667_, loc_1668_
			loc_1668_ = buffer_read_i32(loc_1661_[1], loc_1662_, 60);
			loc_1666_ = loc_1661_;
			rt_store_i32(loc_1666_, loc_1662_, 60, rt_or_i32(bit32_or(loc_1668_ + -1, 0), loc_1668_))
			loc_1667_ = buffer_read_i32(loc_1666_[1], loc_1662_, 0);
			if rt_equal_i32(rt_and_i32(loc_1667_, 8), 0) then
				loc_1664_ = loc_1663_;
				loc_1668_ = loc_1662_;
				rt_store_i64(loc_1666_, loc_1668_, 4, into_bits_i64(0, 0))
				loc_1667_ = buffer_read_i32(loc_1666_[1], loc_1668_, 40);
				rt_store_i32(loc_1666_, loc_1668_, 24, loc_1667_)
				rt_store_i32(loc_1666_, loc_1668_, 20, loc_1667_)
				loc_1665_ = buffer_read_i32(loc_1666_[1], loc_1668_, 44);
				rt_store_i32(loc_1666_, loc_1668_, 16, bit32_or(loc_1667_ + loc_1665_, 0))
				loc_1665_ = 0;
			else
				loc_1664_ = loc_1663_;
				loc_1668_ = loc_1662_;
				rt_store_i32(loc_1666_, loc_1668_, 0, rt_or_i32(loc_1667_, 32))
				loc_1665_ = -1;
			end
			return loc_1665_, loc_1664_
		end), "i32->i32")
	end)(module_locals[3]);
	module_locals[122] = { nil };
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[122][1] = (function(loc_1669_, loc_1670_, loc_1671_)
		return rt_function_type(--[[fn:__fwritex]](function(loc_1672_, loc_1673_, loc_1674_, loc_1675_)
			local loc_1676_, loc_1677_, loc_1678_, loc_1679_, loc_1680_, loc_1681_, loc_1682_, loc_1683_, loc_1684_, loc_1685_, loc_1686_, loc_1687_
			loc_1685_ = buffer_read_i32(loc_1671_[1], loc_1674_, 16);
			loc_1679_ = loc_1671_;
			loc_1682_ = 0;
			loc_1681_ = 0;
			if rt_not_equal_i32(loc_1685_, 0) then
				loc_1676_ = loc_1675_;
				loc_1677_ = loc_1672_;
				loc_1678_ = loc_1670_;
				loc_1680_ = loc_1669_;
				loc_1683_ = loc_1673_;
				loc_1684_ = loc_1674_;
				loc_1687_ = 0;
			else
				loc_1676_ = loc_1675_;
				loc_1677_ = loc_1672_;
				loc_1678_ = loc_1670_;
				loc_1680_ = loc_1669_;
				loc_1683_ = loc_1673_;
				loc_1684_ = loc_1674_;
				loc_1687_ = loc_1681_;
				loc_1687_ = loc_1676_;
				loc_1687_ = loc_1680_[1](loc_1684_, loc_1687_)
				loc_1681_ = 0;
				if rt_not_equal_i32(loc_1687_, 0) then
					loc_1687_ = 1;
				else
					loc_1687_ = loc_1685_;
					loc_1685_ = buffer_read_i32(loc_1679_[1], loc_1684_, 16);
					loc_1687_ = 0;
				end
			end
			if rt_not_equal_i32(loc_1687_, 0) then
				loc_1682_ = 0;
			else
				loc_1687_ = buffer_read_i32(loc_1679_[1], loc_1684_, 20);
				if rt_less_than_equal_u32(loc_1683_, bit32_or(loc_1685_ - loc_1687_, 0)) then
					loc_1685_ = loc_1683_;
					loc_1683_ = loc_1687_;
					loc_1686_ = loc_1682_;
					loc_1687_ = buffer_read_i32(loc_1679_[1], loc_1684_, 64);
					loc_1682_ = 0;
					if rt_less_than_s32(loc_1687_, 0) then
						loc_1686_ = 0;
					else
						if rt_equal_i32(loc_1685_, 0) then
							loc_1686_ = 0;
						else
							loc_1687_ = loc_1676_;
							loc_1677_, loc_1682_ = loc_1682_, loc_1677_;
							loc_1682_, loc_1685_ = loc_1685_, loc_1682_;
							loc_1685_, loc_1681_ = loc_1681_, loc_1685_;
							loc_1676_ = loc_1686_;
							loc_1677_ = loc_1681_;
							loc_1685_ = loc_1682_;
							loc_1686_ = 0;
							loc_1682_ = bit32_or(loc_1681_ + loc_1682_, 0);
							loc_1681_ = loc_1687_;
							repeat
								rt_yield_budget = rt_yield_budget - 1
								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
								loc_1687_ = loc_1676_;
								loc_1687_ = rt_load_i32_from_u8(loc_1679_, bit32_or(bit32_or(loc_1682_ + loc_1686_, 0) + -1, 0), 0);
								if rt_equal_i32(loc_1687_, 10) then
									loc_1687_ = 0;
									loc_1676_ = 1;
								else
									loc_1686_ = bit32_or(loc_1686_ + -1, 0);
									if rt_not_equal_i32(bit32_or(loc_1685_ + loc_1686_, 0), 0) then
										loc_1687_ = 1;
										loc_1676_ = 65535;
									else
										loc_1687_ = 0;
										loc_1676_ = 0;
									end
								end
							until loc_1687_ == 0
							if rt_not_equal_i32(loc_1676_, 0) then
								loc_1682_ = buffer_read_i32(loc_1679_[1], loc_1684_, 32);
								loc_1676_ = rt_table_get_function(loc_1678_, loc_1682_, "i32,i32,i32->i32");
								loc_1682_ = bit32_or(loc_1685_ + loc_1686_, 0);
								loc_1681_ = loc_1676_(loc_1684_, loc_1677_, loc_1682_, loc_1681_)
								if rt_less_than_u32(loc_1681_, loc_1682_) then
									loc_1686_ = 1;
								else
									loc_1685_, loc_1686_ = loc_1686_, loc_1685_;
									loc_1683_ = buffer_read_i32(loc_1679_[1], loc_1684_, 20);
									loc_1686_ = 0;
									loc_1677_ = bit32_or(loc_1682_ + loc_1677_, 0);
									loc_1685_ = bit32_or(0 - loc_1685_, 0);
								end
							else
								loc_1676_ = loc_1681_;
								loc_1686_ = 0;
								loc_1681_ = loc_1682_;
								loc_1682_ = 0;
							end
						end
					end
					if rt_not_equal_i32(loc_1686_, 0) then
						loc_1682_ = 0;
					else
						if rt_equal_i32(loc_1685_, 0) then
							loc_1682_, loc_1684_ = loc_1684_, loc_1682_;
							loc_1684_, loc_1685_ = loc_1685_, loc_1684_;
						else
							loc_1682_, loc_1684_ = loc_1684_, loc_1682_;
							loc_1684_, loc_1685_ = loc_1685_, loc_1684_;
							rt_memory_copy(loc_1679_, loc_1683_, loc_1679_, loc_1677_, loc_1684_)
						end
						loc_1683_ = buffer_read_i32(loc_1679_[1], loc_1682_, 20);
						rt_store_i32(loc_1679_, loc_1682_, 20, bit32_or(loc_1683_ + loc_1684_, 0))
						loc_1682_ = 0;
						loc_1681_ = bit32_or(loc_1685_ + loc_1684_, 0);
					end
				else
					loc_1685_ = loc_1683_;
					loc_1686_ = loc_1687_;
					loc_1687_ = loc_1682_;
					loc_1687_ = buffer_read_i32(loc_1679_[1], loc_1684_, 32);
					loc_1686_ = rt_table_get_function(loc_1678_, loc_1687_, "i32,i32,i32->i32");
					loc_1687_ = loc_1676_;
					loc_1677_ = loc_1686_(loc_1684_, loc_1677_, loc_1685_, loc_1687_)
					loc_1682_ = 1;
				end
			end
			if not (rt_not_equal_i32(loc_1682_, 0)) then
				loc_1677_ = loc_1681_;
			end
			return loc_1677_, loc_1676_
		end), "i32,i32,i32->i32")
	end)(module_locals[121], module_locals[162], module_locals[3]);
	module_locals[123] = { nil };
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[123][1] = (function(loc_1688_, loc_1689_, loc_1690_)
		return rt_function_type(--[[fn:fwrite]](function(loc_1691_, loc_1692_, loc_1693_, loc_1694_, loc_1695_)
			local loc_1696_, loc_1697_, loc_1698_, loc_1699_, loc_1700_, loc_1701_, loc_1702_, loc_1703_, loc_1704_, loc_1705_, loc_1706_, loc_1707_, loc_1708_, loc_1709_, loc_1710_
			loc_1707_ = buffer_read_i32(loc_1690_[1], loc_1694_, 16);
			loc_1699_ = loc_1690_;
			loc_1704_ = 0;
			loc_1703_ = rt_multiply_i32(loc_1693_, loc_1692_);
			loc_1701_ = 0;
			if rt_not_equal_i32(loc_1707_, 0) then
				loc_1696_ = loc_1695_;
				loc_1697_ = loc_1692_;
				loc_1698_ = loc_1689_;
				loc_1700_ = loc_1688_;
				loc_1702_ = loc_1693_;
				loc_1705_ = loc_1691_;
				loc_1706_ = loc_1694_;
				loc_1710_ = 0;
			else
				loc_1696_ = loc_1695_;
				loc_1697_ = loc_1692_;
				loc_1698_ = loc_1689_;
				loc_1700_ = loc_1688_;
				loc_1702_ = loc_1693_;
				loc_1705_ = loc_1691_;
				loc_1706_ = loc_1694_;
				loc_1710_ = loc_1701_;
				loc_1710_ = loc_1696_;
				loc_1710_ = loc_1700_[1](loc_1706_, loc_1710_)
				loc_1701_ = 0;
				if rt_not_equal_i32(loc_1710_, 0) then
					loc_1710_ = 1;
				else
					loc_1710_ = loc_1707_;
					loc_1707_ = buffer_read_i32(loc_1699_[1], loc_1706_, 16);
					loc_1710_ = 0;
				end
			end
			if not (rt_not_equal_i32(loc_1710_, 0)) then
				loc_1710_ = buffer_read_i32(loc_1699_[1], loc_1706_, 20);
				if rt_less_than_equal_u32(loc_1703_, bit32_or(loc_1707_ - loc_1710_, 0)) then
					loc_1707_ = loc_1701_;
					loc_1701_ = loc_1704_;
					loc_1704_ = loc_1710_;
					loc_1708_ = loc_1703_;
					loc_1709_ = loc_1696_;
					loc_1696_ = loc_1705_;
					loc_1703_ = 0;
					if rt_not_equal_i32(loc_1708_, 0) then
						loc_1710_ = buffer_read_i32(loc_1699_[1], loc_1706_, 64);
						loc_1705_ = 0;
						if rt_greater_than_equal_s32(loc_1710_, 0) then
							loc_1707_ = loc_1696_;
							loc_1703_ = loc_1708_;
							loc_1708_ = bit32_or(loc_1696_ + loc_1708_, 0);
							repeat
								rt_yield_budget = rt_yield_budget - 1
								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
								loc_1701_ = rt_load_i32_from_u8(loc_1699_, bit32_or(bit32_or(loc_1708_ + loc_1705_, 0) + -1, 0), 0);
								if rt_equal_i32(loc_1701_, 10) then
									loc_1696_ = 0;
									loc_1701_ = 1;
								else
									loc_1705_ = bit32_or(loc_1705_ + -1, 0);
									if rt_not_equal_i32(bit32_or(loc_1703_ + loc_1705_, 0), 0) then
										loc_1696_ = 1;
										loc_1701_ = 65535;
									else
										loc_1696_ = 0;
										loc_1701_ = 0;
									end
								end
							until loc_1696_ == 0
							if rt_not_equal_i32(loc_1701_, 0) then
								loc_1708_ = buffer_read_i32(loc_1699_[1], loc_1706_, 32);
								loc_1701_ = rt_table_get_function(loc_1698_, loc_1708_, "i32,i32,i32->i32");
								loc_1708_ = bit32_or(loc_1703_ + loc_1705_, 0);
								loc_1701_ = loc_1701_(loc_1706_, loc_1707_, loc_1708_, loc_1709_)
								if rt_less_than_u32(loc_1701_, loc_1708_) then
									loc_1709_ = 1;
								else
									loc_1709_ = loc_1704_;
									loc_1704_ = buffer_read_i32(loc_1699_[1], loc_1706_, 20);
									loc_1709_ = 0;
									loc_1707_ = bit32_or(loc_1708_ + loc_1707_, 0);
									loc_1705_ = bit32_or(0 - loc_1705_, 0);
								end
							else
								loc_1696_ = loc_1709_;
								loc_1709_ = loc_1705_;
								loc_1705_ = loc_1703_;
								loc_1709_ = 0;
								loc_1703_ = loc_1705_;
								loc_1701_ = loc_1708_;
								loc_1708_ = 0;
							end
						else
							loc_1696_, loc_1709_ = loc_1709_, loc_1696_;
							loc_1709_, loc_1701_ = loc_1701_, loc_1709_;
							loc_1701_, loc_1707_ = loc_1707_, loc_1701_;
							loc_1703_, loc_1705_ = loc_1705_, loc_1703_;
							loc_1705_, loc_1708_ = loc_1708_, loc_1705_;
							loc_1709_ = 0;
							loc_1703_ = loc_1705_;
						end
					else
						loc_1705_ = loc_1708_;
						loc_1708_ = loc_1703_;
						loc_1710_ = loc_1709_;
						loc_1709_ = loc_1701_;
						loc_1701_ = loc_1707_;
						loc_1709_ = 0;
						loc_1707_ = loc_1696_;
						loc_1703_ = loc_1705_;
						loc_1696_ = loc_1710_;
					end
					if not (rt_not_equal_i32(loc_1709_, 0)) then
						if rt_equal_i32(loc_1705_, 0) then
							loc_1705_, loc_1706_ = loc_1706_, loc_1705_;
							loc_1706_, loc_1707_ = loc_1707_, loc_1706_;
						else
							loc_1705_, loc_1706_ = loc_1706_, loc_1705_;
							loc_1706_, loc_1707_ = loc_1707_, loc_1706_;
							rt_memory_copy(loc_1699_, loc_1704_, loc_1699_, loc_1706_, loc_1707_)
						end
						loc_1706_ = buffer_read_i32(loc_1699_[1], loc_1705_, 20);
						rt_store_i32(loc_1699_, loc_1705_, 20, bit32_or(loc_1706_ + loc_1707_, 0))
						loc_1701_ = bit32_or(loc_1708_ + loc_1707_, 0);
					end
				else
					loc_1707_ = loc_1701_;
					loc_1708_ = loc_1703_;
					loc_1709_ = loc_1704_;
					loc_1696_, loc_1705_ = loc_1705_, loc_1696_;
					loc_1705_, loc_1710_ = loc_1710_, loc_1705_;
					loc_1709_ = buffer_read_i32(loc_1699_[1], loc_1706_, 32);
					loc_1709_ = rt_table_get_function(loc_1698_, loc_1709_, "i32,i32,i32->i32");
					loc_1701_ = loc_1709_(loc_1706_, loc_1696_, loc_1708_, loc_1710_)
					loc_1703_ = loc_1708_;
				end
			end
			if rt_not_equal_i32(loc_1701_, loc_1703_) then
				loc_1701_ = rt_divide_u32(loc_1701_, loc_1697_);
				loc_1697_ = loc_1701_;
			else
				loc_1701_ = 0;
				if rt_not_equal_i32(loc_1697_, 0) then
					loc_1697_ = loc_1702_;
					loc_1702_ = loc_1701_;
				else
					loc_1701_, loc_1702_ = loc_1702_, loc_1701_;
					loc_1697_ = loc_1702_;
				end
			end
			return loc_1697_, loc_1696_
		end), "i32,i32,i32,i32->i32")
	end)(module_locals[121], module_locals[162], module_locals[3]);
	module_locals[124] = { nil };
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[124][1] = (function(loc_1711_, loc_1712_)
		return rt_function_type(--[[fn:fputs]](function(loc_1713_, loc_1714_, loc_1715_)
			local loc_1716_, loc_1717_, loc_1718_, loc_1719_, loc_1720_
			loc_1717_ = -1;
			loc_1720_ = 0;
			loc_1719_ = loc_1715_;
			loc_1718_ = loc_1712_[1](loc_1713_, loc_1719_)
			loc_1719_ = loc_1711_[1](loc_1713_, 1, loc_1718_, loc_1714_, loc_1719_)
			if rt_not_equal_i32(loc_1718_, loc_1719_) then
				loc_1718_ = loc_1711_;
				loc_1719_ = loc_1712_;
			else
				loc_1718_ = loc_1711_;
				loc_1719_ = loc_1712_;
				loc_1717_ = loc_1720_;
			end
			return loc_1717_, loc_1716_
		end), "i32,i32->i32")
	end)(module_locals[123], module_locals[141]);
	module_locals[125] = { nil };
	module_locals[125][1] = (function(loc_1721_, loc_1722_, loc_1723_, loc_1724_)
		return rt_function_type(--[[fn:__overflow]](function(loc_1725_, loc_1726_, loc_1727_)
			local loc_1728_, loc_1729_, loc_1730_, loc_1731_, loc_1732_, loc_1733_, loc_1734_, loc_1735_, loc_1736_, loc_1737_, loc_1738_
			loc_1738_ = loc_1722_[1];
			loc_1730_ = loc_1722_;
			loc_1733_ = bit32_or(loc_1738_ - 16, 0);
			loc_1730_[1] = loc_1733_;
			rt_store_i32_into_i8(loc_1724_, loc_1733_, 15, loc_1726_)
			loc_1732_ = loc_1724_;
			loc_1729_ = buffer_read_i32(loc_1732_[1], loc_1725_, 16);
			if rt_not_equal_i32(loc_1729_, 0) then
				loc_1728_ = loc_1727_;
				loc_1731_ = loc_1723_;
				loc_1734_ = loc_1721_;
				loc_1735_ = loc_1725_;
				loc_1736_ = loc_1726_;
				loc_1738_ = 0;
			else
				loc_1728_ = loc_1727_;
				loc_1731_ = loc_1723_;
				loc_1734_ = loc_1721_;
				loc_1735_ = loc_1725_;
				loc_1736_ = loc_1726_;
				loc_1738_ = loc_1729_;
				loc_1738_ = loc_1728_;
				loc_1738_ = loc_1734_[1](loc_1735_, loc_1738_)
				if rt_equal_i32(loc_1738_, 0) then
					loc_1729_ = buffer_read_i32(loc_1732_[1], loc_1735_, 16);
					loc_1738_ = 0;
				else
					loc_1738_ = 1;
					loc_1729_ = -1;
				end
			end
			if not (rt_not_equal_i32(loc_1738_, 0)) then
				loc_1737_ = buffer_read_i32(loc_1732_[1], loc_1735_, 20);
				if rt_equal_i32(loc_1737_, loc_1729_) then
					loc_1735_, loc_1736_ = loc_1736_, loc_1735_;
					loc_1735_ = 0;
				else
					loc_1738_ = loc_1729_;
					loc_1735_, loc_1736_ = loc_1736_, loc_1735_;
					loc_1738_ = buffer_read_i32(loc_1732_[1], loc_1736_, 64);
					loc_1729_ = rt_and_i32(loc_1735_, 255);
					if rt_equal_i32(loc_1738_, loc_1729_) then
						loc_1735_, loc_1737_ = loc_1737_, loc_1735_;
						loc_1735_ = 0;
					else
						loc_1735_, loc_1737_ = loc_1737_, loc_1735_;
						rt_store_i32(loc_1732_, loc_1736_, 20, bit32_or(loc_1735_ + 1, 0))
						rt_store_i32_into_i8(loc_1732_, loc_1735_, 0, loc_1737_)
						loc_1735_ = 1;
					end
				end
				if not (rt_not_equal_i32(loc_1735_, 0)) then
					loc_1735_ = loc_1729_;
					loc_1735_ = buffer_read_i32(loc_1732_[1], loc_1736_, 32);
					loc_1729_ = rt_table_get_function(loc_1731_, loc_1735_, "i32,i32,i32->i32");
					loc_1735_ = loc_1728_;
					loc_1736_ = loc_1729_(loc_1736_, bit32_or(loc_1733_ + 15, 0), 1, loc_1735_)
					if rt_equal_i32(loc_1736_, 1) then
						loc_1729_ = rt_load_i32_from_u8(loc_1732_, loc_1733_, 15);
					else
						loc_1729_ = -1;
					end
				end
			end
			loc_1730_[1] = bit32_or(loc_1733_ + 16, 0);
			return loc_1729_, loc_1728_
		end), "i32,i32->i32")
	end)(module_locals[121], module_locals[164], module_locals[162], module_locals[3]);
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[126][1] = (function(loc_1739_, loc_1740_, loc_1741_)
		return rt_function_type(--[[fn:puts]](function(loc_1742_, loc_1743_)
			local loc_1744_, loc_1745_, loc_1746_, loc_1747_, loc_1748_, loc_1749_
			loc_1746_ = loc_1741_;
			loc_1749_ = loc_1743_;
			loc_1749_ = loc_1739_[1](loc_1742_, 10680, loc_1749_)
			if rt_greater_than_equal_s32(loc_1749_, 0) then
				loc_1745_ = loc_1742_;
				loc_1747_ = loc_1739_;
				loc_1748_ = loc_1740_;
				loc_1749_ = buffer_read_i32(loc_1746_[1], 0, 10744);
				if rt_equal_i32(loc_1749_, 10) then
					loc_1749_ = 0;
				else
					loc_1749_ = loc_1745_;
					loc_1745_ = buffer_read_i32(loc_1746_[1], 0, 10700);
					loc_1749_ = buffer_read_i32(loc_1746_[1], 0, 10696);
					if rt_equal_i32(loc_1745_, loc_1749_) then
						loc_1749_ = 0;
					else
						rt_store_i32(loc_1746_, 0, 10700, bit32_or(loc_1745_ + 1, 0))
						rt_store_i32_into_i8(loc_1746_, loc_1745_, 0, 10)
						loc_1749_ = 1;
						loc_1745_ = 0;
					end
				end
				if not (rt_not_equal_i32(loc_1749_, 0)) then
					loc_1744_, loc_1748_ = loc_1748_, loc_1744_;
					loc_1748_, loc_1745_ = loc_1745_, loc_1748_;
					loc_1748_ = loc_1744_;
					loc_1745_ = loc_1744_[1](10680, 10, loc_1745_)
					loc_1745_ = rt_shift_right_s32(loc_1745_, 31);
				end
			else
				loc_1747_ = loc_1739_;
				loc_1748_ = loc_1740_;
				loc_1749_ = loc_1742_;
				loc_1745_ = -1;
			end
			return loc_1745_, loc_1744_
		end), "i32->i32")
	end)(module_locals[124], module_locals[125], module_locals[3]);
	module_locals[129] = { nil };
	module_locals[127][1] = (function(loc_1750_, loc_1751_, loc_1752_)
		return rt_function_type(--[[fn:snprintf]](function(loc_1753_, loc_1754_, loc_1755_, loc_1756_, loc_1757_)
			local loc_1758_, loc_1759_, loc_1760_, loc_1761_, loc_1762_
			loc_1762_ = loc_1751_[1];
			loc_1760_ = loc_1751_;
			loc_1762_ = bit32_or(loc_1762_ - 16, 0);
			loc_1760_[1] = loc_1762_;
			rt_store_i32(loc_1752_, loc_1762_, 12, loc_1756_)
			loc_1761_ = loc_1752_;
			loc_1759_ = loc_1757_;
			loc_1759_ = loc_1750_[1](loc_1753_, loc_1754_, loc_1755_, loc_1756_, loc_1759_)
			loc_1760_[1] = bit32_or(loc_1762_ + 16, 0);
			return loc_1759_, loc_1758_
		end), "i32,i32,i32,i32->i32")
	end)(module_locals[129], module_locals[164], module_locals[3]);
	module_locals[128] = { nil };
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[128][1] = (function(loc_1763_, loc_1764_, loc_1765_)
		return rt_function_type(--[[fn:__stdout_write]](function(loc_1766_, loc_1767_, loc_1768_, loc_1769_)
			local loc_1770_, loc_1771_, loc_1772_, loc_1773_, loc_1774_, loc_1775_, loc_1776_, loc_1777_
			rt_store_i32(loc_1765_, loc_1766_, 32, 8)
			loc_1772_ = loc_1765_;
			loc_1777_ = rt_load_i32_from_u8(loc_1772_, loc_1766_, 0);
			if rt_not_equal_i32(rt_and_i32(loc_1777_, 64), 0) then
				loc_1770_ = loc_1768_;
				loc_1771_ = loc_1769_;
				loc_1773_ = loc_1767_;
				loc_1774_ = loc_1766_;
				loc_1775_ = loc_1764_;
				loc_1776_ = loc_1763_;
			else
				loc_1770_ = loc_1768_;
				loc_1773_ = loc_1767_;
				loc_1774_ = loc_1766_;
				loc_1775_ = loc_1764_;
				loc_1776_ = loc_1763_;
				loc_1777_ = loc_1769_;
				loc_1771_ = buffer_read_i32(loc_1772_[1], loc_1774_, 56);
				loc_1777_ = loc_1776_[1](loc_1771_, loc_1777_)
				if not (rt_not_equal_i32(loc_1777_, 0)) then
					rt_store_i32(loc_1772_, loc_1774_, 64, -1)
				end
			end
			loc_1771_ = loc_1775_[1](loc_1774_, loc_1773_, loc_1770_, loc_1771_)
			return loc_1771_, loc_1770_
		end), "i32,i32,i32->i32")
	end)(module_locals[101], module_locals[105], module_locals[3]);
	module_locals[129][1] = (function(loc_1778_, loc_1779_, loc_1780_)
		return rt_function_type(--[[fn:vsnprintf]](function(loc_1781_, loc_1782_, loc_1783_, loc_1784_, loc_1785_)
			local loc_1786_, loc_1787_, loc_1788_, loc_1789_, loc_1790_, loc_1791_, loc_1792_, loc_1793_, loc_1794_, loc_1795_, loc_1796_
			loc_1796_ = loc_1779_[1];
			loc_1788_ = loc_1779_;
			loc_1796_ = bit32_or(loc_1796_ - 128, 0);
			loc_1788_[1] = loc_1796_;
			loc_1794_ = bit32_or(loc_1796_ + 126, 0);
			if rt_not_equal_i32(loc_1782_, 0) then
				loc_1786_ = loc_1784_;
				loc_1787_ = loc_1785_;
				loc_1789_ = loc_1780_;
				loc_1790_ = loc_1782_;
				loc_1791_ = loc_1783_;
				loc_1792_ = loc_1778_;
				loc_1793_ = loc_1781_;
				loc_1795_ = loc_1796_;
			else
				loc_1786_ = loc_1784_;
				loc_1787_ = loc_1785_;
				loc_1789_ = loc_1780_;
				loc_1790_ = loc_1782_;
				loc_1791_ = loc_1783_;
				loc_1792_ = loc_1778_;
				loc_1793_ = loc_1781_;
				loc_1795_ = loc_1796_;
				loc_1793_ = loc_1794_;
			end
			rt_store_i32(loc_1789_, loc_1796_, 116, loc_1793_)
			loc_1794_ = 0;
			loc_1796_ = bit32_or(loc_1790_ + -1, 0);
			if rt_greater_than_u32(loc_1796_, loc_1790_) then
				loc_1790_ = loc_1795_;
			else
				loc_1790_ = loc_1795_;
				loc_1794_ = loc_1796_;
			end
			rt_store_i32(loc_1789_, loc_1795_, 120, loc_1794_)
			if not (rt_equal_i32(112, 0)) then
				rt_memory_fill(loc_1789_, loc_1790_, 0, 112)
			end
			rt_store_i32_into_i8(loc_1789_, loc_1793_, 0, 0)
			rt_store_i32(loc_1789_, loc_1790_, 64, -1)
			rt_store_i32(loc_1789_, loc_1790_, 32, 12)
			rt_store_i32(loc_1789_, loc_1790_, 68, bit32_or(loc_1790_ + 116, 0))
			rt_store_i32(loc_1789_, loc_1790_, 40, bit32_or(loc_1790_ + 127, 0))
			loc_1787_ = loc_1792_[1](loc_1790_, loc_1791_, loc_1786_, loc_1787_)
			loc_1788_[1] = bit32_or(loc_1790_ + 128, 0);
			return loc_1787_, loc_1786_
		end), "i32,i32,i32,i32->i32")
	end)(module_locals[150], module_locals[164], module_locals[3]);
	module_locals[130] = { nil };
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[130][1] = (function(loc_1797_)
		return rt_function_type(--[[fn:sn_write]](function(loc_1798_, loc_1799_, loc_1800_, loc_1801_)
			local loc_1802_, loc_1803_, loc_1804_, loc_1805_, loc_1806_, loc_1807_, loc_1808_, loc_1809_, loc_1810_, loc_1811_, loc_1812_
			loc_1808_ = buffer_read_i32(loc_1797_[1], loc_1798_, 68);
			loc_1804_ = loc_1797_;
			loc_1805_ = buffer_read_i32(loc_1804_[1], loc_1808_, 0);
			loc_1811_ = buffer_read_i32(loc_1804_[1], loc_1808_, 4);
			loc_1812_ = buffer_read_i32(loc_1804_[1], loc_1798_, 20);
			loc_1803_ = buffer_read_i32(loc_1804_[1], loc_1798_, 24);
			loc_1812_ = bit32_or(loc_1812_ - loc_1803_, 0);
			if rt_less_than_u32(loc_1811_, loc_1812_) then
				loc_1802_ = loc_1801_;
				loc_1806_ = loc_1798_;
				loc_1807_ = loc_1799_;
				loc_1809_ = loc_1811_;
				loc_1810_ = loc_1800_;
			else
				loc_1802_ = loc_1801_;
				loc_1806_ = loc_1798_;
				loc_1807_ = loc_1799_;
				loc_1809_ = loc_1811_;
				loc_1810_ = loc_1800_;
				loc_1811_ = loc_1812_;
			end
			if not (rt_equal_i32(loc_1811_, 0)) then
				if rt_equal_i32(loc_1811_, 0) then
					loc_1809_ = loc_1811_;
					loc_1811_ = loc_1805_;
					loc_1805_ = loc_1803_;
				else
					loc_1809_ = loc_1811_;
					loc_1811_ = loc_1805_;
					loc_1805_ = loc_1803_;
					rt_memory_copy(loc_1804_, loc_1811_, loc_1804_, loc_1805_, loc_1809_)
				end
				loc_1811_ = buffer_read_i32(loc_1804_[1], loc_1808_, 0);
				loc_1805_ = bit32_or(loc_1811_ + loc_1809_, 0);
				rt_store_i32(loc_1804_, loc_1808_, 0, loc_1805_)
				loc_1811_ = buffer_read_i32(loc_1804_[1], loc_1808_, 4);
				loc_1809_ = bit32_or(loc_1811_ - loc_1809_, 0);
				rt_store_i32(loc_1804_, loc_1808_, 4, loc_1809_)
			end
			if rt_less_than_u32(loc_1809_, loc_1810_) then
				loc_1803_ = loc_1810_;
			else
				loc_1803_ = loc_1810_;
				loc_1809_ = loc_1810_;
			end
			if not (rt_equal_i32(loc_1809_, 0)) then
				if rt_equal_i32(loc_1809_, 0) then
					loc_1807_, loc_1808_ = loc_1808_, loc_1807_;
					loc_1808_, loc_1809_ = loc_1809_, loc_1808_;
				else
					loc_1807_, loc_1808_ = loc_1808_, loc_1807_;
					loc_1808_, loc_1809_ = loc_1809_, loc_1808_;
					rt_memory_copy(loc_1804_, loc_1805_, loc_1804_, loc_1809_, loc_1808_)
				end
				loc_1809_ = buffer_read_i32(loc_1804_[1], loc_1807_, 0);
				loc_1805_ = bit32_or(loc_1809_ + loc_1808_, 0);
				rt_store_i32(loc_1804_, loc_1807_, 0, loc_1805_)
				loc_1809_ = buffer_read_i32(loc_1804_[1], loc_1807_, 4);
				rt_store_i32(loc_1804_, loc_1807_, 4, bit32_or(loc_1809_ - loc_1808_, 0))
			end
			rt_store_i32_into_i8(loc_1804_, loc_1805_, 0, 0)
			loc_1805_ = buffer_read_i32(loc_1804_[1], loc_1806_, 40);
			rt_store_i32(loc_1804_, loc_1806_, 24, loc_1805_)
			rt_store_i32(loc_1804_, loc_1806_, 20, loc_1805_)
			return loc_1803_, loc_1802_
		end), "i32,i32,i32->i32")
	end)(module_locals[3]);
	module_locals[131] = { nil };
	module_locals[132] = { nil };
	module_locals[133] = { nil };
	end)() end --[[/spider:chunk]]
	module_locals[131][1] = (function(loc_1813_, loc_1814_, loc_1815_, loc_1816_)
		return rt_function_type(--[[fn:__qsort_r]](function(loc_1817_, loc_1818_, loc_1819_, loc_1820_, loc_1821_, loc_1822_)
			local loc_1823_, loc_1824_, loc_1825_, loc_1826_, loc_1827_, loc_1828_, loc_1829_, loc_1830_, loc_1831_, loc_1832_, loc_1833_, loc_1834_, loc_1835_, loc_1836_, loc_1837_, loc_1838_, loc_1839_, loc_1840_, loc_1841_
			loc_1841_ = loc_1815_[1];
			loc_1824_ = loc_1815_;
			loc_1826_ = bit32_or(loc_1841_ - 208, 0);
			loc_1824_[1] = loc_1826_;
			rt_store_i64(loc_1816_, loc_1826_, 8, into_bits_i64(1, 0))
			loc_1825_ = loc_1816_;
			loc_1834_ = rt_multiply_i32(loc_1819_, loc_1818_);
			if rt_equal_i32(loc_1834_, 0) then
				loc_1823_ = loc_1822_;
				loc_1827_ = loc_1813_;
				loc_1828_ = loc_1814_;
				loc_1829_ = loc_1817_;
				loc_1830_ = loc_1818_;
				loc_1831_ = loc_1819_;
				loc_1832_ = loc_1820_;
				loc_1833_ = loc_1821_;
			else
				loc_1823_ = loc_1822_;
				loc_1827_ = loc_1813_;
				loc_1828_ = loc_1814_;
				loc_1829_ = loc_1817_;
				loc_1830_ = loc_1818_;
				loc_1832_ = loc_1820_;
				loc_1833_ = loc_1821_;
				loc_1838_ = loc_1826_;
				loc_1840_ = loc_1819_;
				rt_store_i32(loc_1825_, loc_1838_, 16, loc_1840_)
				rt_store_i32(loc_1825_, loc_1838_, 20, loc_1840_)
				loc_1836_ = loc_1829_;
				loc_1839_ = loc_1830_;
				loc_1837_ = loc_1840_;
				loc_1831_ = loc_1832_;
				loc_1830_ = loc_1833_;
				loc_1826_ = loc_1838_;
				loc_1841_ = loc_1834_;
				loc_1838_ = rt_or_i32(bit32_or(loc_1838_ + 16, 0), 8);
				loc_1835_ = loc_1840_;
				loc_1834_ = loc_1840_;
				loc_1840_ = loc_1823_;
				repeat
					rt_yield_budget = rt_yield_budget - 1
					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
					loc_1832_ = loc_1841_;
					loc_1841_ = loc_1834_;
					loc_1834_ = loc_1835_;
					loc_1833_ = bit32_or(bit32_or(loc_1841_ + loc_1837_, 0) + loc_1834_, 0);
					rt_store_i32(loc_1825_, loc_1838_, 0, loc_1833_)
					loc_1841_ = loc_1832_;
					loc_1838_ = bit32_or(loc_1838_ + 4, 0);
					loc_1835_ = loc_1833_;
				until not (rt_less_than_u32(loc_1833_, loc_1832_))
				if rt_greater_than_equal_s32(bit32_or(loc_1841_ - loc_1837_, 0), 1) then
					loc_1835_ = buffer_read_i32(loc_1825_[1], loc_1826_, 12);
					loc_1833_ = buffer_read_i32(loc_1825_[1], loc_1826_, 8);
					loc_1834_ = loc_1836_;
					loc_1832_ = loc_1837_;
					loc_1839_ = rt_multiply_i32(loc_1837_, bit32_or(loc_1839_ + -1, 0));
					loc_1829_ = 1;
					loc_1838_ = 1;
					loc_1837_ = bit32_or(bit32_or(loc_1836_ + loc_1841_, 0) - loc_1837_, 0);
					loc_1836_ = 0;
					repeat
						rt_yield_budget = rt_yield_budget - 1
						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
						if rt_not_equal_i32(rt_and_i32(loc_1838_, 3), 3) then
							loc_1823_ = loc_1835_;
							loc_1835_ = loc_1834_;
							loc_1834_ = loc_1829_;
							loc_1829_ = loc_1836_;
							loc_1841_ = loc_1837_;
							loc_1837_ = loc_1832_;
							loc_1832_ = loc_1838_;
							loc_1838_ = loc_1833_;
							loc_1833_ = loc_1826_;
							loc_1826_ = loc_1827_;
							loc_1836_ = bit32_or(loc_1834_ + -1, 0);
							loc_1827_ = buffer_read_i32(loc_1825_[1], bit32_or(bit32_or(loc_1833_ + 16, 0) + rt_shift_left_i32(loc_1836_, 2), 0), 0);
							if rt_less_than_u32(loc_1827_, loc_1839_) then
								loc_1827_ = loc_1826_;
								loc_1826_[1](loc_1835_, loc_1837_, loc_1831_, loc_1830_, loc_1834_, bit32_or(loc_1833_ + 16, 0), loc_1840_)
							else
								loc_1826_, loc_1828_ = loc_1828_, loc_1826_;
								loc_1827_ = loc_1828_;
								loc_1828_ = loc_1826_;
								loc_1826_[1](loc_1835_, loc_1837_, loc_1831_, loc_1830_, bit32_or(loc_1833_ + 8, 0), loc_1834_, 0, bit32_or(loc_1833_ + 16, 0), loc_1840_)
							end
							if rt_not_equal_i32(loc_1834_, 1) then
								loc_1829_ = (rt_greater_than_u32(loc_1836_, 31) and 1 or 0);
								if rt_not_equal_i32(loc_1829_, 0) then
									loc_1826_ = loc_1833_;
								else
									loc_1826_ = loc_1833_;
									loc_1838_ = loc_1823_;
								end
								loc_1834_ = bit32_or(loc_1834_ + -33, 0);
								if not (rt_not_equal_i32(loc_1829_, 0)) then
									loc_1834_ = loc_1836_;
								end
								loc_1836_ = rt_shift_left_i32(loc_1838_, loc_1834_);
								loc_1838_ = 0;
								if not (rt_not_equal_i32(loc_1829_, 0)) then
									loc_1838_ = loc_1832_;
								end
								loc_1836_ = rt_or_i32(loc_1836_, rt_shift_right_u32(loc_1838_, bit32_or(32 - loc_1834_, 0)));
								rt_store_i32(loc_1825_, loc_1833_, 12, loc_1836_)
								loc_1829_ = 1;
								loc_1838_ = rt_shift_left_i32(loc_1838_, loc_1834_);
							else
								loc_1826_ = loc_1836_;
								loc_1836_ = loc_1834_;
								loc_1834_ = loc_1823_;
								loc_1836_ = rt_or_i32(rt_shift_left_i32(loc_1829_, 1), rt_shift_right_u32(loc_1832_, 31));
								rt_store_i32(loc_1825_, loc_1833_, 12, loc_1836_)
								loc_1826_ = loc_1833_;
								loc_1829_ = 0;
								loc_1838_ = rt_shift_left_i32(loc_1832_, 1);
							end
						else
							loc_1841_ = loc_1837_;
							loc_1837_ = loc_1832_;
							loc_1832_ = loc_1838_;
							loc_1838_ = loc_1836_;
							loc_1836_ = loc_1833_;
							loc_1833_ = loc_1826_;
							loc_1826_ = loc_1827_;
							loc_1829_, loc_1835_ = loc_1835_, loc_1829_;
							loc_1835_, loc_1834_ = loc_1834_, loc_1835_;
							loc_1827_ = loc_1826_;
							loc_1826_[1](loc_1835_, loc_1837_, loc_1831_, loc_1830_, loc_1834_, bit32_or(loc_1833_ + 16, 0), loc_1840_)
							loc_1836_ = rt_shift_right_u32(loc_1838_, 2);
							rt_store_i32(loc_1825_, loc_1833_, 12, loc_1836_)
							loc_1826_ = loc_1833_;
							loc_1829_ = bit32_or(loc_1834_ + 2, 0);
							loc_1838_ = rt_or_i32(rt_shift_left_i32(loc_1838_, 30), rt_shift_right_u32(loc_1832_, 2));
						end
						loc_1838_ = rt_or_i32(loc_1838_, 1);
						rt_store_i32(loc_1825_, loc_1826_, 8, loc_1838_)
						loc_1823_ = bit32_or(loc_1835_ + loc_1837_, 0);
						loc_1834_ = loc_1823_;
						loc_1833_ = loc_1838_;
						loc_1832_ = loc_1837_;
						loc_1839_ = bit32_or(loc_1839_ - loc_1837_, 0);
						loc_1835_ = loc_1836_;
						loc_1837_ = loc_1841_;
					until not (rt_less_than_u32(loc_1823_, loc_1841_))
				else
					loc_1834_ = loc_1836_;
					loc_1833_ = loc_1839_;
					loc_1832_ = loc_1837_;
					loc_1829_ = 1;
					loc_1835_ = 0;
				end
				loc_1828_[1](loc_1834_, loc_1832_, loc_1831_, loc_1830_, bit32_or(loc_1826_ + 8, 0), loc_1829_, 0, bit32_or(loc_1826_ + 16, 0), loc_1840_)
				loc_1836_ = buffer_read_i32(loc_1825_[1], loc_1826_, 8);
				if rt_not_equal_i32(loc_1829_, 1) then
					loc_1840_ = 0;
				else
					if rt_not_equal_i32(loc_1836_, 1) then
						loc_1840_ = 0;
					else
						if rt_equal_i32(loc_1835_, 0) then
							loc_1840_ = 1;
						else
							loc_1840_ = 0;
						end
					end
				end
				if not (rt_not_equal_i32(loc_1840_, 0)) then
					loc_1839_ = loc_1835_;
					loc_1840_ = loc_1836_;
					loc_1837_ = bit32_or(0 - loc_1832_, 0);
					loc_1836_ = bit32_or(loc_1834_ + loc_1837_, 0);
					loc_1835_ = loc_1833_;
					loc_1834_ = loc_1832_;
					loc_1833_ = loc_1831_;
					loc_1832_ = loc_1830_;
					loc_1831_ = loc_1829_;
					loc_1830_ = loc_1839_;
					loc_1829_ = loc_1840_;
					repeat
						rt_yield_budget = rt_yield_budget - 1
						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
						if rt_greater_than_s32(loc_1831_, 1) then
							loc_1838_ = loc_1836_;
							loc_1836_ = loc_1823_;
							loc_1823_ = loc_1830_;
							loc_1830_ = loc_1828_;
							loc_1839_ = loc_1831_;
							loc_1840_ = loc_1829_;
							loc_1828_ = loc_1830_;
							loc_1831_ = bit32_or(loc_1839_ + -2, 0);
							loc_1829_ = rt_shift_right_u32(loc_1840_, 30);
							loc_1823_ = rt_or_i32(rt_shift_left_i32(loc_1823_, 2), loc_1829_);
							rt_store_i32(loc_1825_, loc_1826_, 12, rt_shift_right_u32(loc_1823_, 1))
							rt_store_i32(loc_1825_, loc_1826_, 8, rt_exclusive_or_i32(rt_or_i32(rt_shift_left_i32(loc_1829_, 31), rt_and_i32(rt_shift_left_i32(loc_1840_, 1), 2147483646)), 3))
							loc_1829_ = buffer_read_i32(loc_1825_[1], bit32_or(bit32_or(loc_1826_ + 16, 0) + rt_shift_left_i32(loc_1831_, 2), 0), 0);
							loc_1830_[1](bit32_or(loc_1838_ - loc_1829_, 0), loc_1834_, loc_1833_, loc_1832_, bit32_or(loc_1826_ + 8, 0), bit32_or(loc_1839_ + -1, 0), 1, bit32_or(loc_1826_ + 16, 0), loc_1836_)
							loc_1829_ = buffer_read_i32(loc_1825_[1], loc_1826_, 8);
							rt_store_i32(loc_1825_, loc_1826_, 12, rt_or_i32(rt_shift_right_u32(loc_1829_, 31), rt_and_i32(loc_1823_, -2)))
							rt_store_i32(loc_1825_, loc_1826_, 8, rt_or_i32(rt_shift_left_i32(loc_1829_, 1), 1))
							loc_1830_[1](loc_1838_, loc_1834_, loc_1833_, loc_1832_, bit32_or(loc_1826_ + 8, 0), loc_1831_, 1, bit32_or(loc_1826_ + 16, 0), loc_1836_)
							loc_1830_ = buffer_read_i32(loc_1825_[1], loc_1826_, 12);
							loc_1829_ = buffer_read_i32(loc_1825_[1], loc_1826_, 8);
						else
							loc_1838_ = loc_1836_;
							loc_1836_ = loc_1823_;
							loc_1823_ = loc_1830_;
							loc_1830_ = loc_1828_;
							loc_1839_ = loc_1831_;
							loc_1840_ = loc_1829_;
							loc_1831_ = rt_trailing_zeroes_i32(bit32_or(loc_1840_ + -1, 0));
							if rt_not_equal_i32(loc_1831_, 0) then
								loc_1828_ = loc_1830_;
								loc_1830_ = loc_1823_;
								loc_1823_ = loc_1836_;
								loc_1836_ = loc_1840_;
								loc_1840_ = 32;
								if rt_greater_than_equal_u32(loc_1831_, 32) then
									loc_1829_ = 0;
								else
									loc_1831_, loc_1840_ = loc_1840_, loc_1831_;
									loc_1829_ = 1;
									loc_1835_ = loc_1830_;
									loc_1831_ = loc_1840_;
								end
							else
								loc_1828_ = loc_1830_;
								loc_1830_ = loc_1823_;
								loc_1823_ = loc_1836_;
								loc_1836_ = loc_1840_;
								loc_1840_ = loc_1831_;
								loc_1840_ = rt_trailing_zeroes_i32(loc_1830_);
								if rt_equal_i32(loc_1840_, 0) then
									loc_1835_, loc_1840_ = loc_1840_, loc_1835_;
									loc_1829_ = 1;
									loc_1835_ = loc_1830_;
									loc_1831_ = 0;
									loc_1840_ = 0;
								else
									loc_1829_ = 0;
									loc_1831_ = loc_1840_;
									loc_1840_ = bit32_or(loc_1840_ + 32, 0);
								end
							end
							if not (rt_not_equal_i32(loc_1829_, 0)) then
								loc_1831_, loc_1836_ = loc_1836_, loc_1831_;
								loc_1836_, loc_1835_ = loc_1835_, loc_1836_;
								loc_1835_ = 0;
								loc_1831_ = bit32_or(loc_1840_ + -32, 0);
								loc_1836_ = loc_1830_;
							end
							loc_1830_ = rt_shift_right_u32(loc_1835_, loc_1831_);
							rt_store_i32(loc_1825_, loc_1826_, 12, loc_1830_)
							loc_1829_ = rt_or_i32(rt_shift_left_i32(loc_1835_, bit32_or(32 - loc_1831_, 0)), rt_shift_right_u32(loc_1836_, loc_1831_));
							rt_store_i32(loc_1825_, loc_1826_, 8, loc_1829_)
							loc_1831_ = bit32_or(loc_1840_ + loc_1839_, 0);
						end
						loc_1836_ = bit32_or(loc_1838_ + loc_1837_, 0);
						if rt_not_equal_i32(loc_1831_, 1) then
							loc_1838_ = 1;
						else
							if rt_not_equal_i32(loc_1829_, 1) then
								loc_1838_ = 1;
							else
								if rt_not_equal_i32(loc_1830_, 0) then
									loc_1838_ = 1;
								else
									loc_1838_ = 0;
								end
							end
						end
					until loc_1838_ == 0
				end
			end
			loc_1824_[1] = bit32_or(loc_1826_ + 208, 0);
			return loc_1823_
		end), "i32,i32,i32,i32,i32->")
	end)(module_locals[132], module_locals[133], module_locals[164], module_locals[3]);
	do (function() --[[spider:chunk]]
	module_locals[132][1] = (function(loc_1842_, loc_1843_, loc_1844_)
		return rt_function_type(--[[fn:sift]](function(loc_1845_, loc_1846_, loc_1847_, loc_1848_, loc_1849_, loc_1850_, loc_1851_)
			local loc_1852_, loc_1853_, loc_1854_, loc_1855_, loc_1856_, loc_1857_, loc_1858_, loc_1859_, loc_1860_, loc_1861_, loc_1862_, loc_1863_, loc_1864_, loc_1865_, loc_1866_, loc_1867_, loc_1868_, loc_1869_, loc_1870_, loc_1871_
			loc_1871_ = loc_1842_[1];
			loc_1853_ = loc_1842_;
			loc_1856_ = bit32_or(loc_1871_ - 496, 0);
			loc_1853_[1] = loc_1856_;
			rt_store_i32(loc_1844_, loc_1856_, 0, loc_1845_)
			loc_1855_ = loc_1844_;
			loc_1857_ = 0;
			loc_1858_ = 0;
			if rt_less_than_equal_s32(loc_1849_, 1) then
				loc_1852_ = loc_1851_;
				loc_1854_ = loc_1843_;
				loc_1859_ = loc_1845_;
				loc_1860_ = loc_1846_;
				loc_1861_ = loc_1847_;
				loc_1862_ = loc_1848_;
				loc_1863_ = loc_1849_;
				loc_1864_ = loc_1850_;
			else
				loc_1852_ = loc_1851_;
				loc_1854_ = loc_1843_;
				loc_1861_ = loc_1848_;
				loc_1862_ = loc_1847_;
				loc_1863_ = loc_1849_;
				loc_1868_ = loc_1850_;
				loc_1869_ = loc_1846_;
				loc_1870_ = loc_1856_;
				loc_1871_ = loc_1845_;
				loc_1866_ = loc_1857_;
				loc_1867_ = loc_1858_;
				loc_1865_ = loc_1871_;
				loc_1864_ = loc_1869_;
				loc_1860_ = loc_1863_;
				loc_1859_ = loc_1868_;
				loc_1856_ = loc_1870_;
				loc_1858_ = bit32_or(0 - loc_1869_, 0);
				loc_1857_ = rt_or_i32(loc_1870_, 4);
				loc_1863_ = 1;
				loc_1868_ = loc_1871_;
				repeat
					rt_yield_budget = rt_yield_budget - 1
					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
					loc_1871_ = loc_1852_;
					loc_1852_ = rt_table_get_function(loc_1854_, loc_1862_, "i32,i32,i32->i32");
					loc_1868_ = bit32_or(loc_1868_ + loc_1858_, 0);
					loc_1869_ = bit32_or(loc_1860_ + -2, 0);
					loc_1870_ = buffer_read_i32(loc_1855_[1], bit32_or(loc_1859_ + rt_shift_left_i32(loc_1869_, 2), 0), 0);
					loc_1870_ = bit32_or(loc_1868_ - loc_1870_, 0);
					loc_1871_ = loc_1852_(loc_1865_, loc_1870_, loc_1861_, loc_1871_)
					if rt_less_than_s32(loc_1871_, 0) then
						loc_1866_, loc_1869_ = loc_1869_, loc_1866_;
						loc_1871_ = 0;
					else
						loc_1871_ = loc_1852_;
						loc_1866_, loc_1869_ = loc_1869_, loc_1866_;
						loc_1852_ = rt_table_get_function(loc_1854_, loc_1862_, "i32,i32,i32->i32");
						loc_1871_ = loc_1852_(loc_1865_, loc_1868_, loc_1861_, loc_1871_)
						if rt_greater_than_s32(loc_1871_, -1) then
							loc_1871_ = loc_1869_;
							loc_1869_ = loc_1867_;
							loc_1871_ = 1;
							loc_1869_ = 0;
							loc_1867_ = 1;
						else
							loc_1871_ = 0;
						end
					end
					if not (rt_not_equal_i32(loc_1871_, 0)) then
						loc_1867_ = rt_table_get_function(loc_1854_, loc_1862_, "i32,i32,i32->i32");
						loc_1869_ = loc_1852_;
						loc_1869_ = loc_1867_(loc_1870_, loc_1868_, loc_1861_, loc_1869_)
						loc_1869_ = (rt_greater_than_s32(loc_1869_, -1) and 1 or 0);
						if rt_not_equal_i32(loc_1869_, 0) then
							loc_1867_ = loc_1860_;
							loc_1860_ = loc_1857_;
							loc_1857_, loc_1868_ = loc_1868_, loc_1857_;
							loc_1868_, loc_1870_ = loc_1870_, loc_1868_;
							loc_1870_, loc_1866_ = loc_1866_, loc_1870_;
							loc_1866_, loc_1863_ = loc_1863_, loc_1866_;
						else
							loc_1867_ = loc_1860_;
							loc_1860_ = loc_1857_;
							loc_1857_, loc_1868_ = loc_1868_, loc_1857_;
							loc_1868_, loc_1870_ = loc_1870_, loc_1868_;
							loc_1870_, loc_1866_ = loc_1866_, loc_1870_;
							loc_1866_, loc_1863_ = loc_1863_, loc_1866_;
							loc_1868_ = loc_1857_;
						end
						rt_store_i32(loc_1855_, loc_1860_, 0, loc_1868_)
						loc_1857_ = bit32_or(loc_1863_ + 4, 0);
						loc_1863_ = bit32_or(loc_1866_ + 1, 0);
						loc_1860_ = bit32_or(loc_1867_ + -1, 0);
						if not (rt_not_equal_i32(loc_1869_, 0)) then
							loc_1869_ = loc_1860_;
							loc_1860_ = loc_1870_;
						end
						if rt_greater_than_s32(loc_1860_, 1) then
							loc_1869_ = 1;
							loc_1867_ = 65535;
						else
							loc_1869_ = 0;
							loc_1867_ = 0;
						end
					end
					loc_1866_ = loc_1869_;
				until loc_1869_ == 0
				if rt_not_equal_i32(loc_1867_, 0) then
				end
				if not (rt_less_than_u32(loc_1863_, 2)) then
					loc_1867_ = loc_1864_;
					loc_1864_ = bit32_or(loc_1856_ + rt_shift_left_i32(loc_1863_, 2), 0);
					rt_store_i32(loc_1855_, loc_1864_, 0, bit32_or(loc_1856_ + 240, 0))
					if rt_equal_i32(loc_1867_, 0) then
						loc_1862_ = loc_1863_;
						loc_1863_ = loc_1867_;
					else
						loc_1863_, loc_1867_ = loc_1867_, loc_1863_;
						loc_1862_ = rt_and_i32(loc_1867_, -2);
						loc_1861_ = rt_and_i32(loc_1867_, 1);
						repeat
							rt_yield_budget = rt_yield_budget - 1
							if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
							loc_1858_ = buffer_read_i32(loc_1855_[1], loc_1856_, 0);
							loc_1867_ = 256;
							if rt_less_than_u32(loc_1863_, 256) then
								loc_1857_ = loc_1856_;
								loc_1860_ = loc_1863_;
							else
								loc_1857_ = loc_1856_;
								loc_1860_ = loc_1863_;
								loc_1866_ = loc_1863_;
								loc_1863_ = loc_1867_;
							end
							loc_1859_ = (rt_equal_i32(loc_1863_, 0) and 1 or 0);
							if not (rt_not_equal_i32(loc_1859_, 0)) then
								loc_1867_ = buffer_read_i32(loc_1855_[1], loc_1864_, 0);
								rt_memory_copy(loc_1855_, loc_1867_, loc_1855_, loc_1858_, loc_1863_)
							end
							loc_1865_ = loc_1862_;
							loc_1856_ = loc_1857_;
							repeat
								rt_yield_budget = rt_yield_budget - 1
								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
								loc_1867_ = bit32_or(loc_1857_ + 4, 0);
								loc_1866_ = buffer_read_i32(loc_1855_[1], loc_1867_, 0);
								if rt_not_equal_i32(loc_1859_, 0) then
									loc_1857_, loc_1858_ = loc_1858_, loc_1857_;
									loc_1865_, loc_1866_ = loc_1866_, loc_1865_;
								else
									loc_1857_, loc_1858_ = loc_1858_, loc_1857_;
									loc_1865_, loc_1866_ = loc_1866_, loc_1865_;
									rt_memory_copy(loc_1855_, loc_1857_, loc_1855_, loc_1865_, loc_1863_)
								end
								rt_store_i32(loc_1855_, loc_1858_, 0, bit32_or(loc_1857_ + loc_1863_, 0))
								loc_1857_ = bit32_or(loc_1858_ + 8, 0);
								loc_1858_ = buffer_read_i32(loc_1855_[1], loc_1857_, 0);
								if not (rt_not_equal_i32(loc_1859_, 0)) then
									rt_memory_copy(loc_1855_, loc_1865_, loc_1855_, loc_1858_, loc_1863_)
								end
								rt_store_i32(loc_1855_, loc_1867_, 0, bit32_or(loc_1865_ + loc_1863_, 0))
								loc_1866_ = bit32_or(loc_1866_ + -2, 0);
								loc_1865_ = loc_1866_;
							until loc_1866_ == 0
							if not (rt_equal_i32(loc_1861_, 0)) then
								if rt_not_equal_i32(loc_1859_, 0) then
									loc_1859_ = loc_1857_;
								else
									loc_1859_ = loc_1857_;
									loc_1857_ = buffer_read_i32(loc_1855_[1], bit32_or(loc_1859_ + 4, 0), 0);
									rt_memory_copy(loc_1855_, loc_1858_, loc_1855_, loc_1857_, loc_1863_)
								end
								rt_store_i32(loc_1855_, loc_1859_, 0, bit32_or(loc_1858_ + loc_1863_, 0))
							end
							loc_1860_ = bit32_or(loc_1860_ - loc_1863_, 0);
							loc_1863_ = loc_1860_;
						until loc_1860_ == 0
					end
				end
			end
			loc_1853_[1] = bit32_or(loc_1856_ + 496, 0);
			return loc_1852_
		end), "i32,i32,i32,i32,i32,i32->")
	end)(module_locals[164], module_locals[162], module_locals[3]);
	end)() end --[[/spider:chunk]]
	module_locals[133][1] = (function(loc_1872_, loc_1873_, loc_1874_, loc_1875_)
		return rt_function_type(--[[fn:trinkle]](function(loc_1876_, loc_1877_, loc_1878_, loc_1879_, loc_1880_, loc_1881_, loc_1882_, loc_1883_, loc_1884_)
			local loc_1885_, loc_1886_, loc_1887_, loc_1888_, loc_1889_, loc_1890_, loc_1891_, loc_1892_, loc_1893_, loc_1894_, loc_1895_, loc_1896_, loc_1897_, loc_1898_, loc_1899_, loc_1900_, loc_1901_, loc_1902_, loc_1903_, loc_1904_, loc_1905_, loc_1906_, loc_1907_, loc_1908_
			loc_1908_ = loc_1873_[1];
			loc_1886_ = loc_1873_;
			loc_1889_ = bit32_or(loc_1908_ - 496, 0);
			loc_1886_[1] = loc_1889_;
			rt_store_i32(loc_1875_, loc_1889_, 0, loc_1876_)
			loc_1888_ = loc_1875_;
			loc_1902_ = buffer_read_i32(loc_1888_[1], loc_1880_, 4);
			loc_1901_ = buffer_read_i32(loc_1888_[1], loc_1880_, 0);
			loc_1899_ = 0;
			loc_1900_ = 0;
			loc_1903_ = 0;
			loc_1896_ = 0;
			loc_1904_ = 0;
			if rt_not_equal_i32(loc_1901_, 1) then
				loc_1885_ = loc_1884_;
				loc_1887_ = loc_1874_;
				loc_1890_ = loc_1872_;
				loc_1891_ = loc_1877_;
				loc_1892_ = loc_1878_;
				loc_1893_ = loc_1879_;
				loc_1894_ = loc_1881_;
				loc_1895_ = loc_1883_;
				loc_1897_ = loc_1876_;
				loc_1898_ = loc_1882_;
				loc_1908_ = 0;
			else
				loc_1885_ = loc_1884_;
				loc_1887_ = loc_1874_;
				loc_1890_ = loc_1872_;
				loc_1891_ = loc_1877_;
				loc_1892_ = loc_1878_;
				loc_1893_ = loc_1879_;
				loc_1894_ = loc_1881_;
				loc_1895_ = loc_1883_;
				loc_1897_ = loc_1876_;
				loc_1898_ = loc_1882_;
				if rt_equal_i32(loc_1902_, 0) then
					loc_1908_ = 1;
				else
					loc_1908_ = 0;
				end
			end
			if rt_not_equal_i32(loc_1908_, 0) then
				loc_1899_ = 0;
			else
				loc_1905_ = rt_table_get_function(loc_1887_, loc_1892_, "i32,i32,i32->i32");
				loc_1906_ = bit32_or(loc_1895_ + rt_shift_left_i32(loc_1894_, 2), 0);
				loc_1908_ = buffer_read_i32(loc_1888_[1], loc_1906_, 0);
				loc_1907_ = bit32_or(loc_1897_ - loc_1908_, 0);
				loc_1908_ = loc_1885_;
				loc_1908_ = loc_1905_(loc_1907_, loc_1897_, loc_1893_, loc_1908_)
				if rt_less_than_s32(loc_1908_, 1) then
					loc_1905_ = loc_1903_;
					loc_1903_ = loc_1900_;
					loc_1900_ = loc_1906_;
					loc_1906_ = loc_1904_;
					loc_1904_ = loc_1899_;
					loc_1899_ = loc_1907_;
					loc_1901_, loc_1902_ = loc_1902_, loc_1901_;
					loc_1899_ = 0;
				else
					loc_1905_ = loc_1903_;
					loc_1903_ = loc_1900_;
					loc_1900_ = loc_1906_;
					loc_1906_ = loc_1904_;
					loc_1904_ = loc_1899_;
					loc_1899_ = loc_1907_;
					loc_1901_, loc_1902_ = loc_1902_, loc_1901_;
					loc_1908_ = bit32_or(0 - loc_1891_, 0);
					if rt_not_equal_i32(loc_1898_, 0) then
						loc_1899_, loc_1906_ = loc_1906_, loc_1899_;
						loc_1906_, loc_1904_ = loc_1904_, loc_1906_;
						loc_1904_, loc_1902_ = loc_1902_, loc_1904_;
						loc_1900_, loc_1905_ = loc_1905_, loc_1900_;
						loc_1905_, loc_1903_ = loc_1903_, loc_1905_;
						loc_1903_, loc_1901_ = loc_1901_, loc_1903_;
						loc_1901_, loc_1908_ = loc_1908_, loc_1901_;
						loc_1908_ = 0;
					else
						loc_1899_, loc_1906_ = loc_1906_, loc_1899_;
						loc_1906_, loc_1904_ = loc_1904_, loc_1906_;
						loc_1904_, loc_1902_ = loc_1902_, loc_1904_;
						loc_1900_, loc_1905_ = loc_1905_, loc_1900_;
						loc_1905_, loc_1903_ = loc_1903_, loc_1905_;
						loc_1903_, loc_1901_ = loc_1901_, loc_1903_;
						loc_1901_, loc_1908_ = loc_1908_, loc_1901_;
						if rt_less_than_s32(loc_1894_, 2) then
							loc_1908_ = 0;
						else
							loc_1907_ = loc_1885_;
							loc_1898_, loc_1908_ = loc_1908_, loc_1898_;
							loc_1885_ = rt_table_get_function(loc_1887_, loc_1892_, "i32,i32,i32->i32");
							loc_1908_ = bit32_or(loc_1897_ + loc_1901_, 0);
							loc_1898_ = buffer_read_i32(loc_1888_[1], bit32_or(loc_1898_ + -8, 0), 0);
							loc_1907_ = loc_1885_(loc_1908_, loc_1902_, loc_1893_, loc_1907_)
							if rt_greater_than_s32(loc_1907_, -1) then
								loc_1908_ = 1;
							else
								loc_1907_ = loc_1885_;
								loc_1885_ = rt_table_get_function(loc_1887_, loc_1892_, "i32,i32,i32->i32");
								loc_1908_ = loc_1885_(bit32_or(loc_1908_ - loc_1898_, 0), loc_1902_, loc_1893_, loc_1907_)
								if rt_greater_than_s32(loc_1908_, -1) then
									loc_1908_ = 2;
								else
									loc_1908_ = 0;
								end
							end
						end
					end
					if (loc_1908_) >= 0 and (loc_1908_) < 2 then
						if (loc_1908_) < 1 then
							loc_1907_ = loc_1898_;
							loc_1908_ = loc_1900_;
							rt_store_i32(loc_1888_, loc_1889_, 4, loc_1902_)
							loc_1900_ = rt_trailing_zeroes_i32(bit32_or(loc_1904_ + -1, 0));
							if rt_equal_i32(loc_1900_, 0) then
								loc_1898_ = loc_1908_;
								loc_1907_ = loc_1906_;
								loc_1906_ = loc_1899_;
								loc_1899_ = loc_1894_;
								loc_1908_ = loc_1903_;
								loc_1903_ = loc_1902_;
								loc_1902_ = loc_1901_;
								loc_1901_ = loc_1904_;
								loc_1904_ = rt_trailing_zeroes_i32(loc_1908_);
								if rt_equal_i32(loc_1904_, 0) then
									loc_1898_ = 1;
									loc_1900_ = 0;
									loc_1904_ = 0;
								else
									loc_1898_, loc_1901_ = loc_1901_, loc_1898_;
									loc_1901_, loc_1908_ = loc_1908_, loc_1901_;
									loc_1900_, loc_1904_ = loc_1904_, loc_1900_;
									loc_1898_ = 0;
									loc_1900_ = bit32_or(loc_1900_ + 32, 0);
								end
							else
								loc_1898_ = loc_1908_;
								loc_1907_ = loc_1906_;
								loc_1906_ = loc_1899_;
								loc_1899_ = loc_1894_;
								loc_1908_ = loc_1903_;
								loc_1903_ = loc_1902_;
								loc_1902_ = loc_1901_;
								loc_1901_ = loc_1904_;
								loc_1904_ = loc_1900_;
								loc_1900_ = 32;
								if rt_greater_than_u32(loc_1904_, 31) then
									loc_1898_, loc_1901_ = loc_1901_, loc_1898_;
									loc_1901_, loc_1908_ = loc_1908_, loc_1901_;
									loc_1898_ = 0;
								else
									loc_1898_ = 1;
									loc_1900_ = loc_1904_;
								end
							end
							if not (rt_not_equal_i32(loc_1898_, 0)) then
								loc_1900_, loc_1908_ = loc_1908_, loc_1900_;
								loc_1900_ = loc_1908_;
								loc_1904_ = bit32_or(loc_1908_ + -32, 0);
								loc_1908_ = 0;
							end
							loc_1894_ = bit32_or(loc_1900_ + loc_1899_, 0);
							loc_1898_ = rt_shift_right_u32(loc_1908_, loc_1904_);
							loc_1901_ = rt_or_i32(rt_shift_left_i32(loc_1908_, bit32_or(32 - loc_1904_, 0)), rt_shift_right_u32(loc_1901_, loc_1904_));
							if rt_not_equal_i32(loc_1901_, 1) then
								loc_1908_ = 0;
							else
								if rt_equal_i32(loc_1898_, 0) then
									loc_1908_ = loc_1896_;
									loc_1896_ = loc_1903_;
									loc_1908_ = 1;
									loc_1903_ = loc_1896_;
									loc_1906_ = 2;
								else
									loc_1900_ = loc_1896_;
									loc_1896_ = loc_1903_;
									loc_1908_ = 0;
									loc_1903_ = loc_1896_;
									loc_1896_ = loc_1900_;
								end
							end
							if rt_not_equal_i32(loc_1908_, 0) then
								loc_1907_ = 0;
							else
								loc_1908_ = loc_1901_;
								loc_1901_ = loc_1906_;
								loc_1906_ = loc_1902_;
								loc_1902_ = loc_1904_;
								loc_1904_ = loc_1907_;
								loc_1907_ = loc_1903_;
								loc_1903_ = loc_1889_;
								loc_1889_ = loc_1903_;
								loc_1903_ = rt_or_i32(loc_1903_, 8);
								loc_1901_ = loc_1906_;
								loc_1900_ = loc_1908_;
								loc_1906_ = 2;
								repeat
									rt_yield_budget = rt_yield_budget - 1
									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
									loc_1899_ = loc_1896_;
									loc_1908_ = loc_1885_;
									loc_1885_ = rt_table_get_function(loc_1887_, loc_1892_, "i32,i32,i32->i32");
									loc_1899_ = bit32_or(loc_1895_ + rt_shift_left_i32(loc_1894_, 2), 0);
									loc_1896_ = buffer_read_i32(loc_1888_[1], loc_1899_, 0);
									loc_1896_ = bit32_or(loc_1907_ - loc_1896_, 0);
									loc_1908_ = loc_1885_(loc_1896_, loc_1897_, loc_1893_, loc_1908_)
									if rt_greater_than_equal_s32(loc_1908_, 1) then
										loc_1899_, loc_1904_ = loc_1904_, loc_1899_;
										if rt_less_than_s32(loc_1894_, 2) then
											loc_1904_ = 0;
										else
											loc_1908_ = loc_1904_;
											loc_1904_ = loc_1885_;
											loc_1885_ = rt_table_get_function(loc_1887_, loc_1892_, "i32,i32,i32->i32");
											loc_1902_ = bit32_or(loc_1907_ + loc_1901_, 0);
											loc_1908_ = buffer_read_i32(loc_1888_[1], bit32_or(loc_1908_ + -8, 0), 0);
											loc_1885_ = loc_1885_(loc_1902_, loc_1896_, loc_1893_, loc_1904_)
											if rt_less_than_equal_s32(loc_1885_, -1) then
												loc_1885_ = rt_table_get_function(loc_1887_, loc_1892_, "i32,i32,i32->i32");
												loc_1904_ = loc_1885_(bit32_or(loc_1902_ - loc_1908_, 0), loc_1896_, loc_1893_, loc_1904_)
												if rt_less_than_equal_s32(loc_1904_, -1) then
													loc_1904_ = 0;
												else
													loc_1904_ = loc_1905_;
													loc_1905_ = loc_1899_;
													loc_1904_ = 1;
													loc_1899_ = 0;
													loc_1905_ = 2;
												end
											else
												loc_1899_, loc_1908_ = loc_1908_, loc_1899_;
												loc_1908_, loc_1904_ = loc_1904_, loc_1908_;
												loc_1904_, loc_1905_ = loc_1905_, loc_1904_;
												loc_1904_ = 1;
												loc_1899_ = 0;
												loc_1905_ = 1;
												loc_1885_ = loc_1908_;
											end
										end
										if not (rt_not_equal_i32(loc_1904_, 0)) then
											loc_1904_ = loc_1907_;
											loc_1907_ = loc_1899_;
											rt_store_i32(loc_1888_, loc_1903_, 0, loc_1896_)
											loc_1905_ = rt_trailing_zeroes_i32(bit32_or(loc_1900_ + -1, 0));
											if rt_not_equal_i32(loc_1905_, 0) then
												loc_1899_ = loc_1900_;
												loc_1900_ = loc_1894_;
												loc_1904_ = loc_1903_;
												loc_1907_ = loc_1906_;
												loc_1906_ = loc_1898_;
												loc_1903_ = 32;
												if rt_greater_than_equal_u32(loc_1905_, 32) then
													loc_1899_ = 0;
												else
													loc_1899_, loc_1903_ = loc_1903_, loc_1899_;
													loc_1903_, loc_1905_ = loc_1905_, loc_1903_;
													loc_1905_, loc_1902_ = loc_1902_, loc_1905_;
													loc_1902_, loc_1906_ = loc_1906_, loc_1902_;
													loc_1899_ = 1;
													loc_1905_ = loc_1903_;
												end
											else
												loc_1899_ = loc_1900_;
												loc_1900_ = loc_1894_;
												loc_1904_ = loc_1903_;
												loc_1907_ = loc_1906_;
												loc_1906_ = loc_1898_;
												loc_1905_ = rt_trailing_zeroes_i32(loc_1906_);
												if rt_equal_i32(loc_1905_, 0) then
													loc_1903_ = loc_1902_;
													loc_1902_ = loc_1906_;
													loc_1906_ = loc_1899_;
													loc_1899_ = 1;
													loc_1905_ = 0;
													loc_1903_ = 0;
												else
													loc_1903_ = loc_1905_;
													loc_1905_ = loc_1899_;
													loc_1899_ = 0;
													loc_1905_ = loc_1903_;
													loc_1903_ = bit32_or(loc_1903_ + 32, 0);
												end
											end
											if not (rt_not_equal_i32(loc_1899_, 0)) then
												loc_1905_ = bit32_or(loc_1903_ + -32, 0);
												loc_1902_ = 0;
											end
											loc_1894_ = bit32_or(loc_1903_ + loc_1900_, 0);
											loc_1898_ = rt_shift_right_u32(loc_1902_, loc_1905_);
											loc_1903_ = bit32_or(loc_1904_ + 4, 0);
											loc_1900_ = rt_or_i32(rt_shift_right_u32(loc_1906_, loc_1905_), rt_shift_left_i32(loc_1902_, bit32_or(32 - loc_1905_, 0)));
											loc_1906_ = bit32_or(loc_1907_ + 1, 0);
											if rt_not_equal_i32(loc_1900_, 1) then
												loc_1907_ = loc_1896_;
												loc_1899_ = 1;
												loc_1905_ = 65535;
											else
												loc_1907_ = loc_1896_;
												if rt_not_equal_i32(loc_1898_, 0) then
													loc_1907_ = loc_1896_;
													loc_1899_ = 1;
													loc_1905_ = 65535;
												else
													loc_1907_ = loc_1896_;
													loc_1899_ = 0;
													loc_1905_ = 3;
												end
											end
										end
									else
										loc_1908_ = loc_1904_;
										loc_1904_ = loc_1899_;
										loc_1899_ = 0;
										loc_1905_ = 0;
									end
									loc_1904_ = loc_1899_;
								until loc_1899_ == 0
								if (loc_1905_) >= 0 and (loc_1905_) < 3 then
									if (loc_1905_) < 1 then
										loc_1905_ = loc_1896_;
										loc_1896_ = loc_1907_;
									elseif (loc_1905_) > 1 then
										loc_1905_ = loc_1896_;
										loc_1896_ = loc_1907_;
									else
										loc_1905_ = loc_1896_;
										loc_1896_ = loc_1907_;
									end
								else
								end
								if rt_less_than_u32(loc_1906_, 2) then
									loc_1907_ = 1;
								else
									loc_1907_ = 0;
								end
							end
							if rt_not_equal_i32(loc_1907_, 0) then
								loc_1899_ = 2;
							else
								loc_1905_ = bit32_or(loc_1889_ + rt_shift_left_i32(loc_1906_, 2), 0);
								rt_store_i32(loc_1888_, loc_1905_, 0, bit32_or(loc_1889_ + 240, 0))
								if rt_equal_i32(loc_1891_, 0) then
									loc_1899_ = 2;
								else
									loc_1904_ = loc_1905_;
									loc_1905_ = loc_1891_;
									loc_1907_ = loc_1906_;
									loc_1891_ = loc_1905_;
									loc_1906_ = rt_and_i32(loc_1907_, -2);
									loc_1903_ = rt_and_i32(loc_1907_, 1);
									repeat
										rt_yield_budget = rt_yield_budget - 1
										if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
										loc_1907_ = loc_1897_;
										loc_1899_ = buffer_read_i32(loc_1888_[1], loc_1889_, 0);
										loc_1907_ = 256;
										if rt_less_than_u32(loc_1905_, 256) then
											loc_1902_ = loc_1905_;
										else
											loc_1902_ = loc_1905_;
											loc_1902_ = loc_1907_;
										end
										loc_1900_ = (rt_equal_i32(loc_1902_, 0) and 1 or 0);
										if not (rt_not_equal_i32(loc_1900_, 0)) then
											loc_1907_ = buffer_read_i32(loc_1888_[1], loc_1904_, 0);
											rt_memory_copy(loc_1888_, loc_1907_, loc_1888_, loc_1899_, loc_1902_)
										end
										loc_1901_ = loc_1889_;
										loc_1897_ = loc_1906_;
										repeat
											rt_yield_budget = rt_yield_budget - 1
											if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
											loc_1907_ = loc_1898_;
											loc_1907_ = bit32_or(loc_1901_ + 4, 0);
											loc_1898_ = buffer_read_i32(loc_1888_[1], loc_1907_, 0);
											if rt_not_equal_i32(loc_1900_, 0) then
												loc_1897_, loc_1907_ = loc_1907_, loc_1897_;
											else
												loc_1897_, loc_1907_ = loc_1907_, loc_1897_;
												rt_memory_copy(loc_1888_, loc_1899_, loc_1888_, loc_1898_, loc_1902_)
											end
											rt_store_i32(loc_1888_, loc_1901_, 0, bit32_or(loc_1899_ + loc_1902_, 0))
											loc_1901_ = bit32_or(loc_1901_ + 8, 0);
											loc_1899_ = buffer_read_i32(loc_1888_[1], loc_1901_, 0);
											if not (rt_not_equal_i32(loc_1900_, 0)) then
												rt_memory_copy(loc_1888_, loc_1898_, loc_1888_, loc_1899_, loc_1902_)
											end
											rt_store_i32(loc_1888_, loc_1897_, 0, bit32_or(loc_1898_ + loc_1902_, 0))
											loc_1907_ = bit32_or(loc_1907_ + -2, 0);
											loc_1897_ = loc_1907_;
										until loc_1907_ == 0
										if not (rt_equal_i32(loc_1903_, 0)) then
											if rt_not_equal_i32(loc_1900_, 0) then
												loc_1900_ = loc_1901_;
												loc_1901_ = loc_1899_;
											else
												loc_1900_ = loc_1901_;
												loc_1901_ = loc_1899_;
												loc_1899_ = buffer_read_i32(loc_1888_[1], bit32_or(loc_1900_ + 4, 0), 0);
												rt_memory_copy(loc_1888_, loc_1901_, loc_1888_, loc_1899_, loc_1902_)
											end
											rt_store_i32(loc_1888_, loc_1900_, 0, bit32_or(loc_1901_ + loc_1902_, 0))
										end
										loc_1897_ = loc_1902_;
										loc_1902_ = bit32_or(loc_1905_ - loc_1902_, 0);
										loc_1905_ = loc_1902_;
									until loc_1902_ == 0
									loc_1899_ = 2;
								end
							end
						else
							loc_1899_ = 1;
						end
					else
						loc_1899_ = 1;
					end
				end
			end
			if (loc_1899_) >= 0 and (loc_1899_) < 2 then
				if (loc_1899_) < 1 then
					if rt_not_equal_i32(loc_1898_, 0) then
						loc_1898_ = 2;
					else
						loc_1898_ = 0;
					end
				else
					loc_1898_ = 0;
				end
			else
				loc_1898_ = 1;
			end
			if (loc_1898_) >= 0 and (loc_1898_) < 2 then
				if (loc_1898_) < 1 then
					loc_1896_, loc_1897_ = loc_1897_, loc_1896_;
					loc_1897_ = 0;
				else
					loc_1897_ = 0;
				end
			else
				loc_1897_ = 1;
			end
			if not (rt_not_equal_i32(loc_1897_, 0)) then
				loc_1897_ = loc_1890_;
				loc_1890_ = loc_1897_;
				loc_1897_[1](loc_1896_, loc_1891_, loc_1892_, loc_1893_, loc_1894_, loc_1895_, loc_1885_)
			end
			loc_1886_[1] = bit32_or(loc_1889_ + 496, 0);
			return loc_1885_
		end), "i32,i32,i32,i32,i32,i32,i32,i32->")
	end)(module_locals[132], module_locals[164], module_locals[162], module_locals[3]);
	do (function() --[[spider:chunk]]
	module_locals[134][1] = (function(loc_1909_)
		return rt_function_type(--[[fn:qsort]](function(loc_1910_, loc_1911_, loc_1912_, loc_1913_, loc_1914_)
			local loc_1915_
			loc_1915_ = loc_1914_;
			loc_1909_[1](loc_1910_, loc_1911_, loc_1912_, 13, loc_1913_, loc_1915_)
			return loc_1915_
		end), "i32,i32,i32,i32->")
	end)(module_locals[131]);
	module_locals[135] = { nil };
	module_locals[135][1] = (function(loc_1916_)
		return rt_function_type(--[[fn:wrapper_cmp]](function(loc_1917_, loc_1918_, loc_1919_, loc_1920_)
			local loc_1921_, loc_1922_, loc_1923_
			loc_1921_ = rt_table_get_function(loc_1916_, loc_1919_, "i32,i32->i32");
			loc_1923_ = loc_1916_;
			loc_1922_ = loc_1920_;
			loc_1922_ = loc_1921_(loc_1917_, loc_1918_, loc_1922_)
			return loc_1922_, loc_1921_
		end), "i32,i32,i32->i32")
	end)(module_locals[162]);
	module_locals[136][1] = (function(loc_1924_)
		return rt_function_type(--[[fn:memchr]](function(loc_1925_, loc_1926_, loc_1927_, loc_1928_)
			local loc_1929_, loc_1930_, loc_1931_, loc_1932_, loc_1933_, loc_1934_, loc_1935_, loc_1936_, loc_1937_, loc_1938_
			loc_1932_ = 0;
			loc_1936_ = (rt_not_equal_i32(loc_1927_, 0) and 1 or 0);
			loc_1934_ = 0;
			loc_1935_ = 0;
			if rt_equal_i32(rt_and_i32(loc_1925_, 3), 0) then
				loc_1929_ = loc_1928_;
				loc_1930_ = loc_1925_;
				loc_1931_ = loc_1924_;
				loc_1933_ = loc_1926_;
				loc_1937_ = loc_1927_;
				loc_1938_ = 0;
			else
				loc_1929_ = loc_1928_;
				loc_1930_ = loc_1925_;
				loc_1931_ = loc_1924_;
				loc_1933_ = loc_1926_;
				loc_1937_ = loc_1927_;
				if rt_equal_i32(loc_1937_, 0) then
					loc_1938_ = 0;
				else
					loc_1938_ = loc_1934_;
					loc_1938_ = rt_load_i32_from_u8(loc_1931_, loc_1930_, 0);
					if rt_not_equal_i32(loc_1938_, rt_and_i32(loc_1933_, 255)) then
						loc_1938_ = loc_1936_;
						loc_1935_ = bit32_or(loc_1937_ + -1, 0);
						loc_1936_ = (rt_not_equal_i32(loc_1935_, 0) and 1 or 0);
						loc_1934_ = bit32_or(loc_1930_ + 1, 0);
						if rt_equal_i32(rt_and_i32(loc_1934_, 3), 0) then
							loc_1938_ = 1;
						else
							if rt_equal_i32(loc_1935_, 0) then
								loc_1938_ = 1;
							else
								loc_1938_ = rt_load_i32_from_u8(loc_1931_, loc_1934_, 0);
								if rt_equal_i32(loc_1938_, rt_and_i32(loc_1933_, 255)) then
									loc_1938_ = 2;
								else
									loc_1938_ = loc_1936_;
									loc_1936_ = loc_1934_;
									loc_1935_ = bit32_or(loc_1937_ + -2, 0);
									loc_1936_ = (rt_not_equal_i32(loc_1935_, 0) and 1 or 0);
									loc_1934_ = bit32_or(loc_1930_ + 2, 0);
									if rt_equal_i32(rt_and_i32(loc_1934_, 3), 0) then
										loc_1938_ = 1;
									else
										if rt_equal_i32(loc_1935_, 0) then
											loc_1938_ = 1;
										else
											loc_1938_ = rt_load_i32_from_u8(loc_1931_, loc_1934_, 0);
											if rt_equal_i32(loc_1938_, rt_and_i32(loc_1933_, 255)) then
												loc_1938_ = 2;
											else
												loc_1938_ = loc_1936_;
												loc_1936_ = loc_1934_;
												loc_1935_ = bit32_or(loc_1937_ + -3, 0);
												loc_1936_ = (rt_not_equal_i32(loc_1935_, 0) and 1 or 0);
												loc_1934_ = bit32_or(loc_1930_ + 3, 0);
												if rt_equal_i32(rt_and_i32(loc_1934_, 3), 0) then
													loc_1938_ = 1;
												else
													if rt_equal_i32(loc_1935_, 0) then
														loc_1938_ = 1;
													else
														loc_1938_ = rt_load_i32_from_u8(loc_1931_, loc_1934_, 0);
														if rt_equal_i32(loc_1938_, rt_and_i32(loc_1933_, 255)) then
															loc_1938_ = 2;
														else
															loc_1938_ = loc_1936_;
															loc_1936_ = loc_1937_;
															loc_1937_ = loc_1934_;
															loc_1934_ = loc_1930_;
															loc_1938_ = 1;
															loc_1930_ = loc_1934_;
															loc_1937_ = loc_1936_;
															loc_1935_ = bit32_or(loc_1936_ + -4, 0);
															loc_1936_ = (rt_not_equal_i32(loc_1935_, 0) and 1 or 0);
															loc_1934_ = bit32_or(loc_1934_ + 4, 0);
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
						loc_1934_ = loc_1930_;
						loc_1935_ = loc_1937_;
						loc_1938_ = 2;
						loc_1930_ = loc_1934_;
						loc_1937_ = loc_1935_;
					end
				end
			end
			if (loc_1938_) >= 0 and (loc_1938_) < 2 then
				if (loc_1938_) < 1 then
					loc_1930_, loc_1935_ = loc_1935_, loc_1930_;
					loc_1935_, loc_1937_ = loc_1937_, loc_1935_;
					loc_1937_, loc_1934_ = loc_1934_, loc_1937_;
					loc_1937_ = 0;
					loc_1930_ = loc_1934_;
				else
					loc_1937_ = 0;
				end
			else
				loc_1937_ = 1;
			end
			if rt_not_equal_i32(loc_1937_, 0) then
				loc_1936_ = 0;
			else
				if rt_equal_i32(loc_1936_, 0) then
					loc_1936_ = 1;
				else
					loc_1936_ = rt_load_i32_from_u8(loc_1931_, loc_1934_, 0);
					if rt_equal_i32(loc_1936_, rt_and_i32(loc_1933_, 255)) then
						loc_1936_ = 0;
					else
						if rt_less_than_u32(loc_1935_, 4) then
							loc_1936_ = 0;
						else
							loc_1936_ = loc_1930_;
							loc_1930_ = rt_multiply_i32(rt_and_i32(loc_1933_, 255), 16843009);
							repeat
								rt_yield_budget = rt_yield_budget - 1
								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
								loc_1936_ = loc_1932_;
								loc_1936_ = buffer_read_i32(loc_1931_[1], loc_1934_, 0);
								loc_1936_ = rt_exclusive_or_i32(loc_1936_, loc_1930_);
								if rt_not_equal_i32(rt_and_i32(rt_or_i32(bit32_or(16843008 - loc_1936_, 0), loc_1936_), -2139062144), -2139062144) then
									loc_1936_ = 0;
									loc_1932_ = 1;
								else
									loc_1934_ = bit32_or(loc_1934_ + 4, 0);
									loc_1935_ = bit32_or(loc_1935_ + -4, 0);
									if rt_greater_than_u32(loc_1935_, 3) then
										loc_1936_ = 1;
										loc_1932_ = 65535;
									else
										loc_1936_ = 0;
										loc_1932_ = 0;
									end
								end
							until loc_1936_ == 0
							if rt_not_equal_i32(loc_1932_, 0) then
								loc_1936_ = 1;
							else
								loc_1936_ = 0;
							end
						end
					end
					if rt_not_equal_i32(loc_1936_, 0) then
						loc_1936_ = 0;
					else
						if rt_equal_i32(loc_1935_, 0) then
							loc_1936_ = 1;
						else
							loc_1936_ = 0;
						end
					end
				end
			end
			if rt_not_equal_i32(loc_1936_, 0) then
				loc_1932_ = 0;
			else
				loc_1936_ = loc_1935_;
				loc_1935_ = loc_1934_;
				loc_1934_ = loc_1932_;
				loc_1933_ = rt_and_i32(loc_1933_, 255);
				loc_1932_ = loc_1936_;
				repeat
					rt_yield_budget = rt_yield_budget - 1
					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
					loc_1936_ = loc_1934_;
					loc_1936_ = rt_load_i32_from_u8(loc_1931_, loc_1935_, 0);
					if rt_not_equal_i32(loc_1936_, loc_1933_) then
						loc_1936_ = loc_1932_;
						loc_1935_ = bit32_or(loc_1935_ + 1, 0);
						loc_1932_ = bit32_or(loc_1936_ + -1, 0);
						if rt_not_equal_i32(loc_1932_, 0) then
							loc_1936_ = 1;
							loc_1934_ = 65535;
						else
							loc_1936_ = 0;
							loc_1934_ = 1;
						end
					else
						loc_1936_ = 0;
						loc_1934_ = 0;
					end
				until loc_1936_ == 0
				if rt_not_equal_i32(loc_1934_, 0) then
					loc_1932_ = 0;
				else
					loc_1934_ = loc_1930_;
					loc_1932_ = 1;
					loc_1930_ = loc_1935_;
				end
			end
			if not (rt_not_equal_i32(loc_1932_, 0)) then
				loc_1930_ = 0;
			end
			return loc_1930_, loc_1929_
		end), "i32,i32,i32->i32")
	end)(module_locals[3]);
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[137][1] = (function(loc_1939_)
		return rt_function_type(--[[fn:memcmp]](function(loc_1940_, loc_1941_, loc_1942_, loc_1943_)
			local loc_1944_, loc_1945_, loc_1946_, loc_1947_, loc_1948_, loc_1949_, loc_1950_, loc_1951_, loc_1952_, loc_1953_
			loc_1947_ = 0;
			loc_1945_ = 0;
			loc_1951_ = 0;
			loc_1952_ = 0;
			if rt_equal_i32(loc_1942_, 0) then
				loc_1944_ = loc_1943_;
				loc_1946_ = loc_1939_;
				loc_1948_ = loc_1940_;
				loc_1949_ = loc_1941_;
				loc_1950_ = loc_1942_;
			else
				loc_1944_ = loc_1943_;
				loc_1946_ = loc_1939_;
				loc_1948_ = loc_1940_;
				loc_1949_ = loc_1947_;
				loc_1947_ = loc_1941_;
				loc_1950_ = loc_1942_;
				loc_1953_ = loc_1945_;
				loc_1945_ = loc_1950_;
				loc_1950_ = loc_1953_;
				repeat
					rt_yield_budget = rt_yield_budget - 1
					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
					loc_1953_ = loc_1949_;
					loc_1951_, loc_1952_ = loc_1952_, loc_1951_;
					loc_1951_ = rt_load_i32_from_u8(loc_1946_, loc_1948_, 0);
					loc_1952_ = rt_load_i32_from_u8(loc_1946_, loc_1947_, 0);
					if rt_not_equal_i32(loc_1951_, loc_1952_) then
						loc_1953_ = 0;
						loc_1949_ = 1;
					else
						loc_1948_ = bit32_or(loc_1948_ + 1, 0);
						loc_1947_ = bit32_or(loc_1947_ + 1, 0);
						loc_1945_ = bit32_or(loc_1945_ + -1, 0);
						if rt_not_equal_i32(loc_1945_, 0) then
							loc_1953_ = 1;
							loc_1949_ = 65535;
						else
							loc_1953_ = 0;
							loc_1949_ = 0;
						end
					end
				until loc_1953_ == 0
				if rt_not_equal_i32(loc_1949_, 0) then
					loc_1945_ = bit32_or(loc_1951_ - loc_1952_, 0);
				else
					loc_1951_, loc_1952_ = loc_1952_, loc_1951_;
					loc_1945_ = loc_1950_;
				end
			end
			return loc_1945_, loc_1944_
		end), "i32,i32,i32->i32")
	end)(module_locals[3]);
	module_locals[139] = { nil };
	module_locals[138][1] = (function(loc_1954_, loc_1955_)
		return rt_function_type(--[[fn:strchr]](function(loc_1956_, loc_1957_, loc_1958_)
			local loc_1959_, loc_1960_, loc_1961_, loc_1962_, loc_1963_
			loc_1961_ = loc_1955_;
			loc_1963_ = loc_1958_;
			loc_1960_ = loc_1954_[1](loc_1956_, loc_1957_, loc_1963_)
			loc_1962_ = rt_load_i32_from_u8(loc_1961_, loc_1960_, 0);
			loc_1963_ = 0;
			if rt_equal_i32(loc_1962_, rt_and_i32(loc_1957_, 255)) then
				loc_1962_ = loc_1954_;
			else
				loc_1962_ = loc_1954_;
				loc_1960_ = loc_1963_;
			end
			return loc_1960_, loc_1959_
		end), "i32,i32->i32")
	end)(module_locals[139], module_locals[3]);
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[139][1] = (function(loc_1964_, loc_1965_)
		return rt_function_type(--[[fn:__strchrnul]](function(loc_1966_, loc_1967_, loc_1968_)
			local loc_1969_, loc_1970_, loc_1971_, loc_1972_, loc_1973_, loc_1974_, loc_1975_, loc_1976_, loc_1977_
			loc_1972_ = 0;
			loc_1975_ = rt_and_i32(loc_1967_, 255);
			loc_1976_ = 0;
			if rt_equal_i32(loc_1975_, 0) then
				loc_1969_ = loc_1964_;
				loc_1970_ = loc_1968_;
				loc_1971_ = loc_1965_;
				loc_1973_ = loc_1966_;
				loc_1974_ = loc_1967_;
				loc_1972_ = loc_1969_;
				loc_1970_ = loc_1969_[1](loc_1973_, loc_1970_)
				loc_1970_ = bit32_or(loc_1973_ + loc_1970_, 0);
			else
				loc_1969_ = loc_1964_;
				loc_1970_ = loc_1968_;
				loc_1971_ = loc_1965_;
				loc_1973_ = loc_1966_;
				loc_1974_ = loc_1967_;
				if rt_equal_i32(rt_and_i32(loc_1973_, 3), 0) then
					loc_1969_, loc_1970_ = loc_1970_, loc_1969_;
					loc_1970_, loc_1973_ = loc_1973_, loc_1970_;
					loc_1973_, loc_1975_ = loc_1975_, loc_1973_;
					loc_1975_, loc_1972_ = loc_1972_, loc_1975_;
					loc_1977_ = 0;
				else
					loc_1977_ = loc_1976_;
					loc_1969_, loc_1970_ = loc_1970_, loc_1969_;
					loc_1970_, loc_1973_ = loc_1973_, loc_1970_;
					loc_1973_, loc_1975_ = loc_1975_, loc_1973_;
					loc_1975_, loc_1972_ = loc_1972_, loc_1975_;
					loc_1977_ = rt_load_i32_from_u8(loc_1971_, loc_1970_, 0);
					if rt_not_equal_i32(loc_1977_, 0) then
						if rt_not_equal_i32(loc_1977_, rt_and_i32(loc_1974_, 255)) then
							loc_1976_ = bit32_or(loc_1970_ + 1, 0);
							if rt_not_equal_i32(rt_and_i32(loc_1976_, 3), 0) then
								loc_1977_ = rt_load_i32_from_u8(loc_1971_, loc_1976_, 0);
								if rt_equal_i32(loc_1977_, 0) then
									loc_1977_ = 1;
								else
									if rt_equal_i32(loc_1977_, rt_and_i32(loc_1974_, 255)) then
										loc_1977_ = 1;
									else
										loc_1977_ = loc_1976_;
										loc_1976_ = bit32_or(loc_1970_ + 2, 0);
										if rt_not_equal_i32(rt_and_i32(loc_1976_, 3), 0) then
											loc_1977_ = rt_load_i32_from_u8(loc_1971_, loc_1976_, 0);
											if rt_equal_i32(loc_1977_, 0) then
												loc_1977_ = 1;
											else
												if rt_equal_i32(loc_1977_, rt_and_i32(loc_1974_, 255)) then
													loc_1977_ = 1;
												else
													loc_1977_ = loc_1976_;
													loc_1976_ = bit32_or(loc_1970_ + 3, 0);
													if rt_not_equal_i32(rt_and_i32(loc_1976_, 3), 0) then
														loc_1977_ = rt_load_i32_from_u8(loc_1971_, loc_1976_, 0);
														if rt_equal_i32(loc_1977_, 0) then
															loc_1977_ = 1;
														else
															if rt_equal_i32(loc_1977_, rt_and_i32(loc_1974_, 255)) then
																loc_1977_ = 1;
															else
																loc_1977_ = 0;
																loc_1970_ = bit32_or(loc_1970_ + 4, 0);
															end
														end
													else
														loc_1977_ = loc_1970_;
														loc_1977_ = 0;
														loc_1970_ = loc_1976_;
													end
												end
											end
										else
											loc_1977_ = loc_1970_;
											loc_1977_ = 0;
											loc_1970_ = loc_1976_;
										end
									end
								end
							else
								loc_1977_ = loc_1970_;
								loc_1977_ = 0;
								loc_1970_ = loc_1976_;
							end
						else
							loc_1976_ = loc_1977_;
							loc_1977_ = 2;
						end
					else
						loc_1976_ = loc_1977_;
						loc_1977_ = 2;
					end
				end
				if (loc_1977_) >= 0 and (loc_1977_) < 2 then
					if (loc_1977_) < 1 then
						loc_1977_ = loc_1976_;
						loc_1977_ = buffer_read_i32(loc_1971_[1], loc_1970_, 0);
						if rt_not_equal_i32(rt_and_i32(rt_or_i32(bit32_or(16843008 - loc_1977_, 0), loc_1977_), -2139062144), -2139062144) then
							loc_1976_ = loc_1970_;
							loc_1970_ = loc_1977_;
						else
							loc_1976_ = loc_1970_;
							loc_1970_ = loc_1977_;
							loc_1973_ = rt_multiply_i32(loc_1973_, 16843009);
							repeat
								rt_yield_budget = rt_yield_budget - 1
								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
								loc_1977_ = loc_1975_;
								loc_1970_ = rt_exclusive_or_i32(loc_1970_, loc_1973_);
								if rt_not_equal_i32(rt_and_i32(rt_or_i32(bit32_or(16843008 - loc_1970_, 0), loc_1970_), -2139062144), -2139062144) then
									loc_1977_ = 0;
									loc_1975_ = 1;
								else
									loc_1977_ = loc_1970_;
									loc_1976_ = bit32_or(loc_1976_ + 4, 0);
									loc_1970_ = buffer_read_i32(loc_1971_[1], loc_1976_, 0);
									if rt_equal_i32(rt_and_i32(rt_or_i32(bit32_or(16843008 - loc_1970_, 0), loc_1970_), -2139062144), -2139062144) then
										loc_1977_ = 1;
										loc_1975_ = 65535;
									else
										loc_1977_ = 0;
										loc_1975_ = 0;
									end
								end
							until loc_1977_ == 0
							if rt_not_equal_i32(loc_1975_, 0) then
							end
						end
						loc_1970_ = loc_1976_;
						loc_1976_ = bit32_or(loc_1976_ + -1, 0);
						repeat
							rt_yield_budget = rt_yield_budget - 1
							if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
							loc_1973_ = loc_1970_;
							loc_1976_ = bit32_or(loc_1976_ + 1, 0);
							loc_1970_ = rt_load_i32_from_u8(loc_1971_, loc_1976_, 0);
							if rt_equal_i32(loc_1970_, 0) then
								loc_1973_ = 0;
								loc_1975_ = 1;
							else
								if rt_not_equal_i32(loc_1970_, rt_and_i32(loc_1974_, 255)) then
									loc_1973_ = 1;
									loc_1975_ = 65535;
								else
									loc_1973_ = 0;
									loc_1975_ = 0;
								end
							end
						until loc_1973_ == 0
						if rt_not_equal_i32(loc_1975_, 0) then
							loc_1975_ = 0;
						else
							loc_1975_ = 0;
						end
					else
						loc_1975_ = 0;
					end
				else
					loc_1975_ = 1;
				end
				if not (rt_not_equal_i32(loc_1975_, 0)) then
					loc_1975_ = loc_1970_;
					loc_1970_ = loc_1976_;
				end
			end
			return loc_1970_, loc_1969_
		end), "i32,i32->i32")
	end)(module_locals[141], module_locals[3]);
	module_locals[140][1] = (function(loc_1978_, loc_1979_, loc_1980_)
		return rt_function_type(--[[fn:strdup]](function(loc_1981_, loc_1982_)
			local loc_1983_, loc_1984_, loc_1985_, loc_1986_, loc_1987_, loc_1988_, loc_1989_
			loc_1985_ = loc_1980_;
			loc_1989_ = loc_1982_;
			loc_1989_ = loc_1978_[1](loc_1981_, loc_1989_)
			loc_1989_ = bit32_or(loc_1989_ + 1, 0);
			loc_1984_ = loc_1979_[1](loc_1989_, loc_1988_)
			if rt_equal_i32(loc_1984_, 0) then
				loc_1986_ = loc_1978_;
				loc_1987_ = loc_1979_;
				loc_1988_ = loc_1981_;
			else
				loc_1986_ = loc_1978_;
				loc_1987_ = loc_1979_;
				loc_1988_ = loc_1981_;
				if rt_equal_i32(loc_1989_, 0) then
					loc_1988_, loc_1989_ = loc_1989_, loc_1988_;
				else
					loc_1988_, loc_1989_ = loc_1989_, loc_1988_;
					rt_memory_copy(loc_1985_, loc_1984_, loc_1985_, loc_1989_, loc_1988_)
				end
			end
			return loc_1984_, loc_1983_
		end), "i32->i32")
	end)(module_locals[141], module_locals[156], module_locals[3]);
	module_locals[141][1] = (function(loc_1990_)
		return rt_function_type(--[[fn:strlen]](function(loc_1991_, loc_1992_)
			local loc_1993_, loc_1994_, loc_1995_, loc_1996_, loc_1997_, loc_1998_
			if rt_equal_i32(rt_and_i32(loc_1991_, 3), 0) then
				loc_1993_ = loc_1992_;
				loc_1994_ = loc_1991_;
				loc_1995_ = loc_1990_;
				loc_1996_ = loc_1991_;
				loc_1998_ = 0;
			else
				loc_1993_ = loc_1992_;
				loc_1994_ = loc_1991_;
				loc_1995_ = loc_1990_;
				loc_1996_ = loc_1991_;
				loc_1998_ = rt_load_i32_from_u8(loc_1995_, loc_1994_, 0);
				if rt_not_equal_i32(loc_1998_, 0) then
					loc_1998_ = loc_1996_;
					loc_1996_ = bit32_or(loc_1994_ + 1, 0);
					if rt_equal_i32(rt_and_i32(loc_1996_, 3), 0) then
						loc_1998_ = 0;
					else
						loc_1998_ = rt_load_i32_from_u8(loc_1995_, loc_1996_, 0);
						if rt_equal_i32(loc_1998_, 0) then
							loc_1998_ = 1;
						else
							loc_1998_ = loc_1996_;
							loc_1996_ = bit32_or(loc_1994_ + 2, 0);
							if rt_equal_i32(rt_and_i32(loc_1996_, 3), 0) then
								loc_1998_ = 0;
							else
								loc_1998_ = rt_load_i32_from_u8(loc_1995_, loc_1996_, 0);
								if rt_equal_i32(loc_1998_, 0) then
									loc_1998_ = 1;
								else
									loc_1998_ = loc_1996_;
									loc_1996_ = bit32_or(loc_1994_ + 3, 0);
									if rt_equal_i32(rt_and_i32(loc_1996_, 3), 0) then
										loc_1998_ = 0;
									else
										loc_1998_ = rt_load_i32_from_u8(loc_1995_, loc_1996_, 0);
										if rt_equal_i32(loc_1998_, 0) then
											loc_1998_ = 1;
										else
											loc_1998_ = loc_1996_;
											loc_1996_ = bit32_or(loc_1994_ + 4, 0);
											if rt_not_equal_i32(rt_and_i32(loc_1996_, 3), 0) then
												loc_1998_ = 1;
											else
												loc_1998_ = 0;
											end
										end
									end
								end
							end
						end
					end
				else
					loc_1997_ = loc_1996_;
					loc_1998_ = 2;
					loc_1994_ = bit32_or(loc_1994_ - loc_1994_, 0);
					loc_1996_ = loc_1997_;
				end
			end
			if (loc_1998_) >= 0 and (loc_1998_) < 2 then
				if (loc_1998_) < 1 then
					loc_1998_ = loc_1996_;
					loc_1996_ = bit32_or(loc_1998_ + -5, 0);
					loc_1997_ = bit32_or(loc_1998_ + -4, 0);
					repeat
						rt_yield_budget = rt_yield_budget - 1
						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
						loc_1997_ = bit32_or(loc_1997_ + 4, 0);
						loc_1998_ = buffer_read_i32(loc_1995_[1], loc_1997_, 0);
						loc_1996_ = bit32_or(loc_1996_ + 4, 0);
					until not (rt_equal_i32(rt_and_i32(rt_or_i32(bit32_or(16843008 - loc_1998_, 0), loc_1998_), -2139062144), -2139062144))
					repeat
						rt_yield_budget = rt_yield_budget - 1
						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
						loc_1998_ = rt_load_i32_from_u8(loc_1995_, loc_1997_, 0);
						loc_1996_ = bit32_or(loc_1996_ + 1, 0);
						loc_1997_ = bit32_or(loc_1997_ + 1, 0);
					until loc_1998_ == 0
					loc_1997_ = 0;
				else
					loc_1997_ = 0;
				end
			else
				loc_1997_ = 1;
			end
			if not (rt_not_equal_i32(loc_1997_, 0)) then
				loc_1994_ = bit32_or(loc_1996_ - loc_1994_, 0);
			end
			return loc_1994_, loc_1993_
		end), "i32->i32")
	end)(module_locals[3]);
	module_locals[142] = { nil };
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[142][1] = rt_function_type(--[[fn:dummy]](function(loc_1999_, loc_2000_, loc_2001_)
		local loc_2002_
		loc_2002_ = loc_2001_;
		return loc_1999_, loc_2002_
	end), "i32,i32->i32");
	module_locals[143] = { nil };
	module_locals[143][1] = (function(loc_2003_)
		return rt_function_type(--[[fn:__lctrans]](function(loc_2004_, loc_2005_, loc_2006_)
			local loc_2007_, loc_2008_
			loc_2008_ = loc_2006_;
			loc_2008_ = loc_2003_[1](loc_2004_, loc_2005_, loc_2008_)
			return loc_2008_, loc_2007_
		end), "i32,i32->i32")
	end)(module_locals[142]);
	module_locals[144] = { nil };
	module_locals[144][1] = (function(loc_2009_, loc_2010_)
		return rt_function_type(--[[fn:strerror]](function(loc_2011_, loc_2012_)
			local loc_2013_, loc_2014_, loc_2015_, loc_2016_, loc_2017_, loc_2018_
			loc_2013_ = buffer_read_i32(loc_2010_[1], 0, 28624);
			loc_2015_ = loc_2010_;
			if rt_not_equal_i32(loc_2013_, 0) then
				loc_2014_ = loc_2012_;
				loc_2017_ = loc_2009_;
				loc_2018_ = loc_2011_;
			else
				loc_2014_ = loc_2012_;
				loc_2016_ = loc_2013_;
				loc_2017_ = loc_2009_;
				loc_2018_ = loc_2011_;
				rt_store_i32(loc_2015_, 0, 28624, 28600)
				loc_2013_ = 28600;
			end
			loc_2016_ = 0;
			if not (rt_greater_than_u32(loc_2018_, 76)) then
				loc_2016_ = loc_2018_;
			end
			loc_2016_ = rt_load_i32_from_u16(loc_2015_, rt_shift_left_i32(loc_2016_, 1), 10032);
			loc_2013_ = buffer_read_i32(loc_2015_[1], loc_2013_, 20);
			loc_2014_ = loc_2017_[1](bit32_or(loc_2016_ + 8480, 0), loc_2013_, loc_2014_)
			return loc_2014_, loc_2013_
		end), "i32->i32")
	end)(module_locals[143], module_locals[3]);
	module_locals[145] = { nil };
	module_locals[145][1] = (function(loc_2019_)
		return rt_function_type(--[[fn:strnlen]](function(loc_2020_, loc_2021_, loc_2022_)
			local loc_2023_, loc_2024_, loc_2025_, loc_2026_
			loc_2026_ = loc_2022_;
			loc_2026_ = loc_2019_[1](loc_2020_, 0, loc_2021_, loc_2026_)
			loc_2024_ = bit32_or(loc_2026_ - loc_2020_, 0);
			if rt_not_equal_i32(loc_2026_, 0) then
				loc_2025_ = loc_2019_;
				loc_2026_ = loc_2021_;
			else
				loc_2025_ = loc_2019_;
				loc_2026_ = loc_2021_;
				loc_2024_ = loc_2026_;
			end
			return loc_2024_, loc_2023_
		end), "i32,i32->i32")
	end)(module_locals[136]);
	module_locals[146] = { nil };
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[146][1] = (function(loc_2027_)
		return rt_function_type(--[[fn:wcrtomb]](function(loc_2028_, loc_2029_, loc_2030_, loc_2031_)
			local loc_2032_, loc_2033_, loc_2034_, loc_2035_, loc_2036_, loc_2037_
			loc_2035_ = 1;
			if rt_equal_i32(loc_2028_, 0) then
				loc_2032_ = loc_2031_;
				loc_2033_ = loc_2028_;
				loc_2034_ = loc_2027_;
				loc_2036_ = loc_2029_;
				loc_2036_ = 0;
			else
				loc_2032_ = loc_2031_;
				loc_2033_ = loc_2028_;
				loc_2034_ = loc_2027_;
				loc_2036_ = loc_2029_;
				if rt_greater_than_u32(loc_2036_, 127) then
					loc_2037_ = loc_2035_;
					loc_2035_ = buffer_read_i32(loc_2034_[1], 0, 28624);
					if not (rt_not_equal_i32(loc_2035_, 0)) then
						loc_2037_ = loc_2035_;
						rt_store_i32(loc_2034_, 0, 28624, 28600)
						loc_2035_ = 28600;
					end
					loc_2037_ = buffer_read_i32(loc_2034_[1], loc_2035_, 0);
					if rt_not_equal_i32(loc_2037_, 0) then
						if rt_greater_than_u32(loc_2036_, 2047) then
							if rt_less_than_u32(loc_2036_, 55296) then
								loc_2037_ = 0;
							else
								if rt_not_equal_i32(rt_and_i32(loc_2036_, -8192), 57344) then
									if rt_greater_than_u32(bit32_or(loc_2036_ + -65536, 0), 1048575) then
										rt_store_i32(loc_2034_, 0, 27520, 25)
										loc_2037_ = 1;
									else
										rt_store_i32_into_i8(loc_2034_, loc_2033_, 3, rt_or_i32(rt_and_i32(loc_2036_, 63), 128))
										rt_store_i32_into_i8(loc_2034_, loc_2033_, 0, rt_or_i32(rt_shift_right_u32(loc_2036_, 18), 240))
										rt_store_i32_into_i8(loc_2034_, loc_2033_, 2, rt_or_i32(rt_and_i32(rt_shift_right_u32(loc_2036_, 6), 63), 128))
										rt_store_i32_into_i8(loc_2034_, loc_2033_, 1, rt_or_i32(rt_and_i32(rt_shift_right_u32(loc_2036_, 12), 63), 128))
										loc_2037_ = 2;
										loc_2033_ = 4;
									end
								else
									loc_2037_ = 0;
								end
							end
							if (loc_2037_) >= 0 and (loc_2037_) < 2 then
								if (loc_2037_) < 1 then
									rt_store_i32_into_i8(loc_2034_, loc_2033_, 2, rt_or_i32(rt_and_i32(loc_2036_, 63), 128))
									rt_store_i32_into_i8(loc_2034_, loc_2033_, 0, rt_or_i32(rt_shift_right_u32(loc_2036_, 12), 224))
									rt_store_i32_into_i8(loc_2034_, loc_2033_, 1, rt_or_i32(rt_and_i32(rt_shift_right_u32(loc_2036_, 6), 63), 128))
									loc_2036_ = 3;
									loc_2033_ = 3;
								else
									loc_2036_ = 0;
								end
							else
								loc_2036_ = 4;
							end
						else
							rt_store_i32_into_i8(loc_2034_, loc_2033_, 1, rt_or_i32(rt_and_i32(loc_2036_, 63), 128))
							rt_store_i32_into_i8(loc_2034_, loc_2033_, 0, rt_or_i32(rt_shift_right_u32(loc_2036_, 6), 192))
							loc_2036_ = 2;
							loc_2033_ = 2;
						end
					else
						if rt_equal_i32(rt_and_i32(loc_2036_, -128), 57216) then
							loc_2037_ = loc_2036_;
							loc_2036_ = loc_2033_;
							rt_store_i32_into_i8(loc_2034_, loc_2036_, 0, loc_2037_)
							loc_2036_ = 1;
							loc_2033_ = 1;
						else
							loc_2037_ = loc_2033_;
							rt_store_i32(loc_2034_, 0, 27520, 25)
							loc_2036_ = 0;
							loc_2033_ = loc_2037_;
						end
					end
					if (loc_2036_) >= 0 and (loc_2036_) < 4 then
						if (loc_2036_) < 2 then
							if (loc_2036_) < 1 then
								loc_2036_ = loc_2035_;
								loc_2036_ = 0;
								loc_2035_ = -1;
							else
								loc_2036_ = 1;
							end
						elseif (loc_2036_) > 2 then
							loc_2036_ = 1;
						else
							loc_2036_ = 1;
						end
					else
						loc_2036_ = 1;
					end
				else
					loc_2037_ = loc_2035_;
					rt_store_i32_into_i8(loc_2034_, loc_2033_, 0, loc_2036_)
					loc_2036_ = 1;
					loc_2033_ = 1;
					loc_2035_ = loc_2037_;
				end
			end
			if not (rt_not_equal_i32(loc_2036_, 0)) then
				loc_2033_ = loc_2035_;
			end
			return loc_2033_, loc_2032_
		end), "i32,i32,i32->i32")
	end)(module_locals[3]);
	module_locals[147] = { nil };
	module_locals[147][1] = (function(loc_2038_)
		return rt_function_type(--[[fn:wctomb]](function(loc_2039_, loc_2040_, loc_2041_)
			local loc_2042_, loc_2043_, loc_2044_, loc_2045_, loc_2046_
			if rt_not_equal_i32(loc_2039_, 0) then
				loc_2042_ = loc_2040_;
				loc_2043_ = loc_2041_;
				loc_2045_ = loc_2039_;
				loc_2046_ = loc_2038_;
				loc_2044_ = loc_2046_;
				loc_2043_ = loc_2046_[1](loc_2045_, loc_2042_, 0, loc_2043_)
			else
				loc_2043_ = loc_2040_;
				loc_2044_ = loc_2039_;
				loc_2045_ = loc_2038_;
				loc_2046_ = loc_2041_;
				loc_2044_ = loc_2045_;
				loc_2043_ = 0;
				loc_2042_ = loc_2046_;
			end
			return loc_2043_, loc_2042_
		end), "i32,i32->i32")
	end)(module_locals[146]);
	module_locals[148] = { nil };
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[148][1] = (function(loc_2047_, loc_2048_)
		return rt_function_type(--[[fn:frexp]](function(loc_2049_, loc_2050_, loc_2051_)
			local loc_2052_, loc_2053_, loc_2054_, loc_2055_, loc_2056_, loc_2057_, loc_2058_
			loc_2057_ = rt_transmute_f64_to_i64(loc_2049_);
			loc_2058_ = rt_and_i32(rt_low_shift_right_u64(loc_2057_, 52), 2047);
			if rt_equal_i32(loc_2058_, 2047) then
				loc_2052_ = loc_2051_;
				loc_2053_ = loc_2049_;
				loc_2054_ = loc_2048_;
				loc_2055_ = loc_2047_;
				loc_2056_ = loc_2050_;
				loc_2056_ = 0;
			else
				loc_2052_ = loc_2051_;
				loc_2053_ = loc_2049_;
				loc_2054_ = loc_2048_;
				loc_2055_ = loc_2047_;
				loc_2056_ = loc_2050_;
				if rt_not_equal_i32(loc_2058_, 0) then
					loc_2057_, loc_2058_ = loc_2058_, loc_2057_;
					rt_store_i32(loc_2054_, loc_2056_, 0, bit32_or(loc_2057_ + -1022, 0))
					loc_2056_ = 0;
					loc_2053_ = rt_transmute_i64_to_f64(rt_or_i64(rt_and_i64(loc_2058_, into_bits_i64(4294967295, 2148532223)), into_bits_i64(0, 1071644672)));
				else
					loc_2057_, loc_2058_ = loc_2058_, loc_2057_;
					if rt_not_equal_f64(loc_2053_, 0) then
						loc_2057_ = loc_2056_;
						loc_2056_ = loc_2053_;
						loc_2053_ = loc_2055_;
						loc_2058_ = loc_2052_;
						loc_2055_ = loc_2053_;
						loc_2053_ = loc_2053_[1](rt_multiply_f64(loc_2056_, 1.8446744073709552e19), loc_2057_, loc_2058_)
						loc_2058_ = buffer_read_i32(loc_2054_[1], loc_2057_, 0);
						rt_store_i32(loc_2054_, loc_2057_, 0, bit32_or(loc_2058_ + -64, 0))
						loc_2056_ = 1;
					else
						loc_2057_ = loc_2053_;
						loc_2053_ = loc_2055_;
						loc_2058_ = loc_2052_;
						loc_2055_ = loc_2053_;
						rt_store_i32(loc_2054_, loc_2056_, 0, 0)
						loc_2056_ = 1;
						loc_2053_ = loc_2057_;
						loc_2052_ = loc_2058_;
					end
				end
			end
			if rt_not_equal_i32(loc_2056_, 0) then
			end
			return loc_2053_, loc_2052_
		end), "f64,i32->f64")
	end)(module_locals[148], module_locals[3]);
	module_locals[149] = { nil };
	module_locals[149][1] = rt_function_type(--[[fn:abort]](function(loc_2059_)
		local loc_2060_, loc_2061_
		loc_2060_ = loc_2059_;
		loc_2061_ = error('unreachable code');
		return loc_2060_
	end), "->");
	module_locals[151] = { nil };
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[150][1] = (function(loc_2062_, loc_2063_, loc_2064_, loc_2065_, loc_2066_)
		return rt_function_type(--[[fn:vfprintf]](function(loc_2067_, loc_2068_, loc_2069_, loc_2070_)
			local loc_2071_, loc_2072_, loc_2073_, loc_2074_, loc_2075_, loc_2076_, loc_2077_, loc_2078_, loc_2079_, loc_2080_, loc_2081_, loc_2082_, loc_2083_
			loc_2083_ = loc_2064_[1];
			loc_2073_ = loc_2064_;
			loc_2076_ = bit32_or(loc_2083_ - 208, 0);
			loc_2073_[1] = loc_2076_;
			rt_store_i32(loc_2066_, loc_2076_, 204, loc_2069_)
			loc_2075_ = loc_2066_;
			rt_store_i64(loc_2075_, bit32_or(bit32_or(loc_2076_ + 160, 0) + 32, 0), 0, into_bits_i64(0, 0))
			rt_store_i64(loc_2075_, bit32_or(loc_2076_ + 184, 0), 0, into_bits_i64(0, 0))
			rt_store_i64(loc_2075_, bit32_or(loc_2076_ + 176, 0), 0, into_bits_i64(0, 0))
			rt_store_i64(loc_2075_, loc_2076_, 168, into_bits_i64(0, 0))
			rt_store_i64(loc_2075_, loc_2076_, 160, into_bits_i64(0, 0))
			rt_store_i32(loc_2075_, loc_2076_, 200, loc_2069_)
			loc_2074_ = loc_2065_;
			loc_2083_ = loc_2070_;
			loc_2083_ = loc_2063_[1](0, loc_2068_, bit32_or(loc_2076_ + 200, 0), bit32_or(loc_2076_ + 80, 0), bit32_or(loc_2076_ + 160, 0), loc_2083_)
			if rt_greater_than_equal_s32(loc_2083_, 0) then
				loc_2072_ = loc_2068_;
				loc_2077_ = loc_2062_;
				loc_2078_ = loc_2063_;
				loc_2079_ = loc_2069_;
				loc_2081_ = loc_2067_;
				loc_2082_ = buffer_read_i32(loc_2075_[1], loc_2081_, 0);
				rt_store_i32(loc_2075_, loc_2081_, 0, rt_and_i32(loc_2082_, -33))
				loc_2083_ = buffer_read_i32(loc_2075_[1], loc_2081_, 44);
				if rt_not_equal_i32(loc_2083_, 0) then
					loc_2083_ = buffer_read_i32(loc_2075_[1], loc_2081_, 16);
					loc_2080_ = 0;
					if rt_not_equal_i32(loc_2083_, 0) then
						loc_2083_ = 1;
					else
						loc_2083_ = 0;
					end
				else
					rt_store_i32(loc_2075_, loc_2081_, 44, 80)
					rt_store_i32(loc_2075_, loc_2081_, 24, 0)
					rt_store_i64(loc_2075_, loc_2081_, 16, into_bits_i64(0, 0))
					loc_2080_ = buffer_read_i32(loc_2075_[1], loc_2081_, 40);
					rt_store_i32(loc_2075_, loc_2081_, 40, loc_2076_)
					loc_2083_ = 0;
				end
				if rt_not_equal_i32(loc_2083_, 0) then
					loc_2083_ = 0;
				else
					loc_2083_ = loc_2079_;
					loc_2083_ = loc_2071_;
					loc_2083_ = loc_2077_[1](loc_2081_, loc_2083_)
					loc_2079_ = -1;
					if rt_not_equal_i32(loc_2083_, 0) then
						loc_2083_ = 1;
					else
						loc_2083_ = 0;
					end
				end
				if not (rt_not_equal_i32(loc_2083_, 0)) then
					loc_2071_, loc_2078_ = loc_2078_, loc_2071_;
					loc_2078_, loc_2079_ = loc_2079_, loc_2078_;
					loc_2078_ = loc_2071_;
					loc_2079_ = loc_2071_[1](loc_2081_, loc_2072_, bit32_or(loc_2076_ + 200, 0), bit32_or(loc_2076_ + 80, 0), bit32_or(loc_2076_ + 160, 0), loc_2079_)
				end
				loc_2072_ = rt_and_i32(loc_2082_, 32);
				if not (rt_equal_i32(loc_2080_, 0)) then
					loc_2082_ = loc_2071_;
					loc_2071_ = buffer_read_i32(loc_2075_[1], loc_2081_, 32);
					loc_2071_ = rt_table_get_function(loc_2074_, loc_2071_, "i32,i32,i32->i32");
					loc_2082_ = loc_2071_(loc_2081_, 0, 0, loc_2082_)
					rt_store_i32(loc_2075_, loc_2081_, 44, 0)
					rt_store_i32(loc_2075_, loc_2081_, 40, loc_2080_)
					rt_store_i32(loc_2075_, loc_2081_, 24, 0)
					loc_2082_ = buffer_read_i32(loc_2075_[1], loc_2081_, 20);
					rt_store_i64(loc_2075_, loc_2081_, 16, into_bits_i64(0, 0))
					loc_2080_ = -1;
					if not (rt_not_equal_i32(loc_2082_, 0)) then
						loc_2079_ = loc_2080_;
					end
				end
				loc_2080_ = buffer_read_i32(loc_2075_[1], loc_2081_, 0);
				rt_store_i32(loc_2075_, loc_2081_, 0, rt_or_i32(loc_2080_, loc_2072_))
				loc_2072_ = -1;
				if not (rt_not_equal_i32(rt_and_i32(loc_2080_, 32), 0)) then
					loc_2072_ = loc_2079_;
				end
			else
				loc_2077_ = loc_2062_;
				loc_2078_ = loc_2063_;
				loc_2081_ = loc_2069_;
				loc_2082_ = loc_2068_;
				loc_2083_ = loc_2067_;
				loc_2072_ = -1;
			end
			loc_2073_[1] = bit32_or(loc_2076_ + 208, 0);
			return loc_2072_, loc_2071_
		end), "i32,i32,i32->i32")
	end)(module_locals[121], module_locals[151], module_locals[164], module_locals[162], module_locals[3]);
	module_locals[152] = { nil };
	module_locals[153] = { nil };
	end)() end --[[/spider:chunk]]
	module_locals[151][1] = (function(loc_2084_, loc_2085_, loc_2086_, loc_2087_, loc_2088_, loc_2089_, loc_2090_, loc_2091_, loc_2092_)
		local __spider_scoped_dependencies = { loc_2084_, loc_2085_, loc_2086_, loc_2087_, loc_2088_, loc_2089_, loc_2090_, loc_2091_, loc_2092_ }
		return rt_function_type(--[[fn:printf_core]](function(loc_2093_, loc_2094_, loc_2095_, loc_2096_, loc_2097_, loc_2098_)
			local from_bits_f64, rt_add_i64, rt_convert_s32_to_f64, rt_convert_u32_to_f64, rt_divide_s32, rt_extend_s8_to_i32, rt_greater_than_equal_u64, rt_less_than_f64, rt_less_than_u64, rt_load_f64 = runtime.from_bits_f64, runtime.rt_add_i64, runtime.rt_convert_s32_to_f64, runtime.rt_convert_u32_to_f64, runtime.rt_divide_s32, runtime.rt_extend_s8_to_i32, runtime.rt_greater_than_equal_u64, runtime.rt_less_than_f64, runtime.rt_less_than_u64, runtime.rt_load_f64
			local loc_2099_, loc_2100_, loc_2101_, loc_2102_, loc_2103_, loc_2104_, loc_2105_, loc_2106_, loc_2107_, loc_2108_, loc_2109_, loc_2110_, loc_2111_, loc_2112_, loc_2113_, loc_2114_, loc_2115_, loc_2116_, loc_2117_, loc_2118_, loc_2119_, loc_2120_, loc_2121_, loc_2122_, loc_2123_, loc_2124_, loc_2125_, loc_2126_, loc_2127_, loc_2128_, loc_2129_, loc_2130_, loc_2131_, loc_2132_, loc_2133_, loc_2134_, loc_2135_, loc_2136_, loc_2137_, loc_2138_, loc_2139_, loc_2140_, loc_2141_, loc_2142_, loc_2143_, loc_2144_, loc_2145_, loc_2146_, loc_2147_, loc_2148_, loc_2149_, loc_2150_, loc_2151_, loc_2152_, loc_2153_
			loc_2104_ = __spider_scoped_dependencies[1];
			loc_2105_ = __spider_scoped_dependencies[2];
			loc_2106_ = __spider_scoped_dependencies[3];
			loc_2107_ = __spider_scoped_dependencies[4];
			loc_2108_ = __spider_scoped_dependencies[5];
			loc_2109_ = __spider_scoped_dependencies[6];
			loc_2110_ = __spider_scoped_dependencies[7];
			loc_2153_ = __spider_scoped_dependencies[8][1];
			loc_2101_ = __spider_scoped_dependencies[8];
			loc_2153_ = bit32_or(loc_2153_ - 864, 0);
			loc_2101_[1] = loc_2153_;
			loc_2102_ = __spider_scoped_dependencies[9];
			loc_2117_ = 0;
			loc_2111_ = 0;
			loc_2112_ = loc_2093_;
			loc_2118_ = loc_2094_;
			loc_2113_ = loc_2095_;
			loc_2114_ = loc_2096_;
			loc_2115_ = loc_2097_;
			loc_2103_ = loc_2153_;
			loc_2119_ = bit32_or(bit32_or(loc_2153_ + 52, 0) + 12, 0);
			loc_2120_ = bit32_or(bit32_or(loc_2153_ + 96, 0) + -4, 0);
			loc_2121_ = bit32_or(bit32_or(loc_2153_ + 16, 0) + 25, 0);
			loc_2122_ = bit32_or(loc_2153_ + 39, 0);
			loc_2123_ = bit32_or(bit32_or(loc_2153_ + 52, 0) + 11, 0);
			loc_2124_ = bit32_or(bit32_or(loc_2153_ + 64, 0) + -1, 0);
			loc_2125_ = rt_or_i32(bit32_or(loc_2153_ + 64, 0), 8);
			loc_2126_ = rt_or_i32(bit32_or(loc_2153_ + 64, 0), 9);
			loc_2127_ = bit32_or(bit32_or(loc_2153_ + 52, 0) + 10, 0);
			loc_2128_ = bit32_or(loc_2153_ + 40, 0);
			loc_2116_ = 0;
			loc_2100_ = 0;
			loc_2129_ = 0;
			loc_2130_ = 0;
			loc_2131_ = 0;
			loc_2132_ = 0;
			loc_2133_ = into_bits_i64(0, 0);
			loc_2134_ = into_bits_i64(0, 0);
			loc_2099_ = loc_2098_;
			repeat
				rt_yield_budget = rt_yield_budget - 1
				if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
				loc_2153_ = loc_2111_;
				loc_2111_ = loc_2117_;
				loc_2117_ = loc_2153_;
				loc_2135_ = 0;
				repeat
					rt_yield_budget = rt_yield_budget - 1
					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
					if rt_greater_than_s32(loc_2135_, rt_exclusive_or_i32(loc_2100_, 2147483647)) then
						loc_2136_ = loc_2111_;
						loc_2111_ = loc_2118_;
						loc_2136_ = 0;
						loc_2117_ = 10;
					else
						loc_2136_ = loc_2111_;
						loc_2111_ = loc_2118_;
						loc_2153_ = loc_2135_;
						loc_2135_ = rt_load_i32_from_u8(loc_2102_, loc_2111_, 0);
						loc_2100_ = bit32_or(loc_2153_ + loc_2100_, 0);
						if rt_equal_i32(loc_2135_, 0) then
							loc_2136_ = 0;
							loc_2117_ = 4;
						else
							loc_2153_ = loc_2118_;
							loc_2153_ = loc_2111_;
							loc_2152_ = loc_2135_;
							repeat
								rt_yield_budget = rt_yield_budget - 1
								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
								loc_2150_ = loc_2117_;
								loc_2151_ = loc_2136_;
								loc_2152_ = rt_and_i32(loc_2152_, 255);
								if rt_equal_i32(loc_2152_, 0) then
									loc_2151_ = 0;
									loc_2117_ = 1;
								else
									if rt_not_equal_i32(loc_2152_, 37) then
										loc_2153_ = bit32_or(loc_2153_ + 1, 0);
										loc_2152_ = rt_load_i32_from_u8(loc_2102_, loc_2153_, 0);
										loc_2151_ = 1;
										loc_2117_ = 65535;
									else
										loc_2151_ = 0;
										loc_2117_ = 0;
									end
								end
								loc_2136_ = loc_2151_;
							until loc_2151_ == 0
							if rt_not_equal_i32(loc_2117_, 0) then
								loc_2118_ = loc_2153_;
							else
								loc_2118_ = loc_2153_;
								repeat
									rt_yield_budget = rt_yield_budget - 1
									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
									loc_2151_ = loc_2117_;
									loc_2152_ = loc_2136_;
									loc_2152_ = rt_load_i32_from_u8(loc_2102_, bit32_or(loc_2118_ + 1, 0), 0);
									if rt_not_equal_i32(loc_2152_, 37) then
										loc_2152_ = 0;
										loc_2117_ = 1;
									else
										loc_2118_ = bit32_or(loc_2118_ + 2, 0);
										loc_2152_ = rt_load_i32_from_u8(loc_2102_, loc_2118_, 0);
										loc_2153_ = bit32_or(loc_2153_ + 1, 0);
										if rt_equal_i32(loc_2152_, 37) then
											loc_2152_ = 1;
											loc_2117_ = 65535;
										else
											loc_2152_ = 0;
											loc_2117_ = 0;
										end
									end
									loc_2136_ = loc_2152_;
								until loc_2152_ == 0
								if rt_not_equal_i32(loc_2117_, 0) then
								end
							end
							loc_2135_ = bit32_or(loc_2153_ - loc_2111_, 0);
							loc_2137_ = rt_exclusive_or_i32(loc_2100_, 2147483647);
							if rt_greater_than_s32(loc_2135_, loc_2137_) then
								loc_2136_ = 0;
								loc_2117_ = 11;
							else
								if rt_equal_i32(loc_2112_, 0) then
									loc_2111_, loc_2137_ = loc_2137_, loc_2111_;
									loc_2137_, loc_2136_ = loc_2136_, loc_2137_;
									loc_2136_, loc_2117_ = loc_2117_, loc_2136_;
								else
									loc_2111_, loc_2137_ = loc_2137_, loc_2111_;
									loc_2137_, loc_2136_ = loc_2136_, loc_2137_;
									loc_2136_, loc_2117_ = loc_2117_, loc_2136_;
									loc_2153_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
									if not (rt_not_equal_i32(rt_and_i32(loc_2153_, 32), 0)) then
										loc_2152_ = loc_2104_;
										loc_2104_ = loc_2152_;
										loc_2153_ = loc_2099_;
										loc_2153_ = loc_2152_[1](loc_2117_, loc_2135_, loc_2112_, loc_2153_)
									end
								end
								if rt_not_equal_i32(loc_2135_, 0) then
									loc_2136_ = 1;
									loc_2117_ = 65535;
								else
									loc_2152_ = loc_2129_;
									loc_2153_ = loc_2135_;
									loc_2139_ = rt_load_i32_from_s8(loc_2102_, loc_2118_, 1);
									loc_2150_ = bit32_or(loc_2139_ + -48, 0);
									loc_2153_ = bit32_or(loc_2118_ + 1, 0);
									loc_2129_ = -1;
									if rt_greater_than_u32(loc_2150_, 9) then
										loc_2151_ = loc_2118_;
										loc_2152_ = loc_2130_;
										loc_2117_, loc_2136_ = loc_2136_, loc_2117_;
										loc_2136_, loc_2137_ = loc_2137_, loc_2136_;
									else
										loc_2151_ = loc_2118_;
										loc_2152_ = loc_2130_;
										loc_2117_, loc_2136_ = loc_2136_, loc_2117_;
										loc_2136_, loc_2137_ = loc_2137_, loc_2136_;
										loc_2149_ = rt_load_i32_from_u8(loc_2102_, loc_2151_, 2);
										if not (rt_not_equal_i32(loc_2149_, 36)) then
											loc_2147_ = loc_2139_;
											loc_2148_ = loc_2129_;
											loc_2149_ = loc_2153_;
											loc_2153_ = loc_2151_;
											loc_2151_ = loc_2150_;
											loc_2150_ = loc_2116_;
											loc_2139_ = rt_load_i32_from_s8(loc_2102_, loc_2153_, 3);
											loc_2116_ = 1;
											loc_2150_ = loc_2151_;
											loc_2153_ = bit32_or(loc_2153_ + 3, 0);
											loc_2129_ = loc_2151_;
										end
									end
									loc_2118_ = bit32_or(loc_2139_ + -32, 0);
									loc_2151_ = 0;
									if rt_less_than_equal_u32(loc_2118_, 31) then
										loc_2135_ = rt_shift_left_i32(1, loc_2118_);
										if rt_not_equal_i32(rt_and_i32(loc_2135_, 75913), 0) then
											loc_2153_ = bit32_or(loc_2153_ + 1, 0);
											loc_2140_ = 0;
											repeat
												rt_yield_budget = rt_yield_budget - 1
												if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
												loc_2147_ = loc_2139_;
												loc_2148_ = loc_2118_;
												loc_2149_ = loc_2117_;
												loc_2150_ = loc_2136_;
												loc_2151_ = loc_2135_;
												loc_2139_ = rt_load_i32_from_s8(loc_2102_, loc_2153_, 0);
												loc_2135_ = bit32_or(loc_2139_ + -32, 0);
												loc_2140_ = rt_or_i32(loc_2151_, loc_2140_);
												if rt_greater_than_equal_u32(loc_2135_, 32) then
													loc_2118_ = loc_2153_;
													loc_2151_ = 0;
													loc_2117_ = 1;
												else
													loc_2118_ = loc_2153_;
													loc_2135_ = rt_shift_left_i32(1, loc_2135_);
													loc_2153_ = bit32_or(loc_2118_ + 1, 0);
													if rt_not_equal_i32(rt_and_i32(loc_2135_, 75913), 0) then
														loc_2151_ = 1;
														loc_2117_ = 65535;
													else
														loc_2151_ = 0;
														loc_2117_ = 0;
													end
												end
												loc_2136_ = loc_2151_;
											until loc_2151_ == 0
											if rt_not_equal_i32(loc_2117_, 0) then
											end
										else
											loc_2150_ = loc_2118_;
											loc_2118_ = loc_2153_;
											loc_2140_ = loc_2151_;
										end
									else
										loc_2149_ = loc_2118_;
										loc_2118_ = loc_2153_;
										loc_2135_ = loc_2150_;
										loc_2140_ = loc_2151_;
									end
									if rt_not_equal_i32(loc_2139_, 42) then
										loc_2138_ = bit32_or(loc_2139_ + -48, 0);
										loc_2130_ = 0;
										if rt_greater_than_u32(loc_2138_, 9) then
											loc_2153_ = 0;
										else
											loc_2151_ = loc_2118_;
											loc_2153_ = loc_2135_;
											loc_2153_ = loc_2136_;
											loc_2152_ = loc_2117_;
											loc_2118_ = loc_2151_;
											loc_2135_ = loc_2151_;
											repeat
												rt_yield_budget = rt_yield_budget - 1
												if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
												loc_2151_ = loc_2118_;
												if rt_greater_than_u32(loc_2130_, 214748364) then
													loc_2151_ = loc_2130_;
													loc_2152_ = loc_2138_;
													loc_2153_ = loc_2135_;
													loc_2118_ = rt_load_i32_from_s8(loc_2102_, loc_2153_, 1);
													loc_2135_ = bit32_or(loc_2153_ + 1, 0);
													loc_2138_ = bit32_or(loc_2118_ + -48, 0);
													loc_2130_ = -1;
													if rt_less_than_u32(loc_2138_, 10) then
														loc_2151_ = 1;
														loc_2152_ = 65535;
													else
														loc_2151_ = 0;
														loc_2152_ = 1;
													end
												else
													loc_2150_ = loc_2139_;
													loc_2151_ = loc_2130_;
													loc_2152_ = loc_2138_;
													loc_2153_ = loc_2135_;
													loc_2151_ = rt_multiply_i32(loc_2151_, 10);
													loc_2139_ = (rt_greater_than_u32(loc_2152_, rt_exclusive_or_i32(loc_2151_, 2147483647)) and 1 or 0);
													loc_2130_ = -1;
													loc_2152_ = bit32_or(loc_2151_ + loc_2152_, 0);
													if rt_not_equal_i32(loc_2139_, 0) then
														loc_2152_, loc_2153_ = loc_2153_, loc_2152_;
													else
														loc_2151_ = loc_2130_;
														loc_2152_, loc_2153_ = loc_2153_, loc_2152_;
														loc_2130_ = loc_2153_;
													end
													loc_2153_ = rt_load_i32_from_s8(loc_2102_, loc_2152_, 1);
													loc_2135_ = bit32_or(loc_2152_ + 1, 0);
													loc_2138_ = bit32_or(loc_2153_ + -48, 0);
													if rt_less_than_u32(loc_2138_, 10) then
														loc_2118_ = loc_2135_;
														loc_2151_ = 1;
														loc_2152_ = 65535;
													else
														loc_2118_ = loc_2135_;
														loc_2151_ = 0;
														loc_2152_ = 0;
													end
												end
												loc_2153_ = loc_2151_;
											until loc_2151_ == 0
											if rt_not_equal_i32(loc_2152_, 0) then
												loc_2153_ = 1;
												loc_2136_ = 0;
												loc_2117_ = 1;
											else
												if rt_not_equal_i32(loc_2139_, 0) then
													loc_2153_ = 1;
													loc_2136_ = 0;
													loc_2117_ = 12;
												else
													loc_2151_ = loc_2153_;
													loc_2153_ = 0;
													loc_2136_ = loc_2151_;
													loc_2117_ = loc_2152_;
												end
											end
										end
									else
										loc_2151_ = loc_2135_;
										loc_2151_ = rt_load_i32_from_s8(loc_2102_, loc_2118_, 1);
										loc_2135_ = bit32_or(loc_2151_ + -48, 0);
										if rt_greater_than_u32(loc_2135_, 9) then
											loc_2130_ = loc_2152_;
											loc_2138_ = loc_2153_;
											loc_2153_ = 0;
										else
											loc_2130_ = loc_2152_;
											loc_2138_ = loc_2153_;
											loc_2153_ = rt_load_i32_from_u8(loc_2102_, loc_2118_, 2);
											if rt_not_equal_i32(loc_2153_, 36) then
												loc_2153_ = 0;
											else
												loc_2152_ = loc_2130_;
												loc_2153_ = loc_2116_;
												if rt_not_equal_i32(loc_2112_, 0) then
													loc_2152_ = loc_2118_;
													loc_2130_ = buffer_read_i32(loc_2102_[1], bit32_or(loc_2114_ + rt_shift_left_i32(loc_2135_, 3), 0), 0);
												else
													loc_2152_ = loc_2118_;
													rt_store_i32(loc_2102_, bit32_or(loc_2115_ + rt_shift_left_i32(loc_2135_, 2), 0), 0, 10)
													loc_2130_ = 0;
												end
												loc_2153_ = 1;
												loc_2118_ = bit32_or(loc_2152_ + 3, 0);
												loc_2116_ = 1;
											end
										end
										if rt_not_equal_i32(loc_2153_, 0) then
											loc_2153_ = 0;
										else
											if rt_not_equal_i32(loc_2116_, 0) then
												loc_2152_ = loc_2117_;
												loc_2153_ = loc_2136_;
												loc_2153_ = 1;
												loc_2136_ = 0;
												loc_2117_ = 5;
											else
												loc_2150_ = loc_2130_;
												loc_2151_ = loc_2116_;
												loc_2152_ = loc_2117_;
												loc_2153_ = loc_2136_;
												loc_2118_ = bit32_or(loc_2118_ + 1, 0);
												if rt_not_equal_i32(loc_2112_, 0) then
													loc_2117_ = loc_2152_;
													loc_2136_ = loc_2153_;
													loc_2153_ = loc_2135_;
													loc_2135_ = buffer_read_i32(loc_2102_[1], loc_2113_, 0);
													rt_store_i32(loc_2102_, loc_2113_, 0, bit32_or(loc_2135_ + 4, 0))
													loc_2130_ = buffer_read_i32(loc_2102_[1], loc_2135_, 0);
													loc_2153_ = 0;
													loc_2116_ = 0;
												else
													loc_2117_ = loc_2152_;
													loc_2136_ = loc_2153_;
													loc_2152_ = loc_2135_;
													loc_2153_ = 2;
													loc_2116_ = 0;
													loc_2135_ = loc_2152_;
													loc_2130_ = 0;
												end
											end
										end
										if (loc_2153_) >= 0 and (loc_2153_) < 2 then
											if (loc_2153_) < 1 then
												if rt_greater_than_s32(loc_2130_, -1) then
													loc_2153_ = 0;
												else
													loc_2153_ = 0;
													loc_2140_ = rt_or_i32(loc_2140_, 8192);
													loc_2130_ = bit32_or(0 - loc_2130_, 0);
												end
											else
												loc_2153_ = 1;
											end
										else
											loc_2153_ = 0;
										end
									end
									if not (rt_not_equal_i32(loc_2153_, 0)) then
										loc_2153_ = loc_2135_;
										loc_2153_ = rt_load_i32_from_u8(loc_2102_, loc_2118_, 0);
										loc_2135_ = 0;
										if rt_equal_i32(loc_2153_, 46) then
											loc_2152_ = loc_2138_;
											loc_2153_ = loc_2118_;
											loc_2111_, loc_2140_ = loc_2140_, loc_2111_;
											loc_2140_, loc_2137_ = loc_2137_, loc_2140_;
											loc_2137_, loc_2139_ = loc_2139_, loc_2137_;
											loc_2152_ = rt_load_i32_from_s8(loc_2102_, loc_2153_, 1);
											if rt_not_equal_i32(loc_2152_, 42) then
												loc_2118_ = bit32_or(loc_2153_ + 1, 0);
												loc_2153_ = bit32_or(loc_2152_ + -48, 0);
												if rt_less_than_equal_u32(loc_2153_, 9) then
													loc_2138_ = 0;
													repeat
														rt_yield_budget = rt_yield_budget - 1
														if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
														loc_2151_ = loc_2131_;
														loc_2152_ = loc_2137_;
														loc_2137_ = -1;
														if rt_greater_than_u32(loc_2138_, 214748364) then
															loc_2151_ = loc_2153_;
															loc_2152_ = loc_2138_;
															loc_2153_ = loc_2118_;
														else
															loc_2150_ = loc_2137_;
															loc_2151_ = loc_2153_;
															loc_2152_ = loc_2138_;
															loc_2153_ = loc_2118_;
															loc_2137_ = -1;
															loc_2150_ = rt_multiply_i32(loc_2152_, 10);
															loc_2152_ = bit32_or(loc_2150_ + loc_2151_, 0);
															if not (rt_greater_than_u32(loc_2151_, rt_exclusive_or_i32(loc_2150_, 2147483647))) then
																loc_2151_ = loc_2137_;
																loc_2137_ = loc_2152_;
															end
														end
														loc_2118_ = bit32_or(loc_2153_ + 1, 0);
														loc_2153_ = rt_load_i32_from_s8(loc_2102_, loc_2118_, 0);
														loc_2138_ = loc_2137_;
														loc_2131_ = 1;
														loc_2152_ = bit32_or(loc_2153_ + -48, 0);
														loc_2153_ = loc_2152_;
													until not (rt_less_than_u32(loc_2152_, 10))
													loc_2153_ = 0;
												else
													loc_2150_ = loc_2153_;
													loc_2151_ = loc_2131_;
													loc_2153_ = loc_2137_;
													loc_2153_ = 0;
													loc_2138_ = loc_2152_;
													loc_2137_ = 0;
													loc_2131_ = 1;
												end
											else
												loc_2152_ = rt_load_i32_from_s8(loc_2102_, loc_2153_, 2);
												loc_2138_ = bit32_or(loc_2152_ + -48, 0);
												if rt_greater_than_u32(loc_2138_, 9) then
													loc_2118_ = loc_2153_;
													loc_2153_ = 0;
												else
													loc_2118_ = loc_2153_;
													loc_2153_ = rt_load_i32_from_u8(loc_2102_, loc_2118_, 3);
													if rt_not_equal_i32(loc_2153_, 36) then
														loc_2153_ = 0;
													else
														loc_2152_ = loc_2131_;
														loc_2153_ = loc_2137_;
														if rt_not_equal_i32(loc_2112_, 0) then
															loc_2151_ = loc_2118_;
															loc_2152_ = buffer_read_i32(loc_2102_[1], bit32_or(loc_2114_ + rt_shift_left_i32(loc_2138_, 3), 0), 0);
															loc_2153_ = 2;
															loc_2118_ = bit32_or(loc_2151_ + 4, 0);
															loc_2137_ = loc_2152_;
															loc_2131_ = (rt_greater_than_s32(loc_2152_, -1) and 1 or 0);
														else
															loc_2151_ = loc_2118_;
															rt_store_i32(loc_2102_, bit32_or(loc_2115_ + rt_shift_left_i32(loc_2138_, 2), 0), 0, 10)
															loc_2153_ = 1;
															loc_2118_ = bit32_or(loc_2151_ + 4, 0);
															loc_2137_ = 0;
															loc_2131_ = (rt_greater_than_s32(0, -1) and 1 or 0);
														end
													end
												end
												if (loc_2153_) >= 0 and (loc_2153_) < 2 then
													if (loc_2153_) < 1 then
														if rt_not_equal_i32(loc_2116_, 0) then
															loc_2152_ = loc_2117_;
															loc_2153_ = loc_2136_;
															loc_2153_ = 1;
															loc_2136_ = 0;
															loc_2117_ = 6;
														else
															loc_2150_ = loc_2131_;
															loc_2151_ = loc_2137_;
															loc_2152_ = loc_2117_;
															loc_2153_ = loc_2136_;
															loc_2118_ = bit32_or(loc_2118_ + 2, 0);
															if rt_not_equal_i32(loc_2112_, 0) then
																loc_2117_ = loc_2152_;
																loc_2136_ = loc_2153_;
																loc_2153_ = loc_2138_;
																loc_2138_ = buffer_read_i32(loc_2102_[1], loc_2113_, 0);
																rt_store_i32(loc_2102_, loc_2113_, 0, bit32_or(loc_2138_ + 4, 0))
																loc_2152_ = buffer_read_i32(loc_2102_[1], loc_2138_, 0);
																loc_2153_ = 0;
																loc_2137_ = loc_2152_;
																loc_2131_ = (rt_greater_than_s32(loc_2152_, -1) and 1 or 0);
															else
																loc_2117_ = loc_2152_;
																loc_2136_ = loc_2153_;
																loc_2152_ = loc_2138_;
																loc_2153_ = 0;
																loc_2138_ = loc_2152_;
																loc_2137_ = 0;
																loc_2131_ = (rt_greater_than_s32(0, -1) and 1 or 0);
															end
														end
													else
														loc_2153_ = 0;
													end
												else
													loc_2153_ = 0;
												end
											end
										else
											loc_2150_ = loc_2131_;
											loc_2151_ = loc_2118_;
											loc_2152_ = loc_2138_;
											loc_2153_ = loc_2139_;
											loc_2139_ = loc_2111_;
											loc_2111_ = loc_2140_;
											loc_2140_ = loc_2137_;
											loc_2153_ = 0;
											loc_2118_ = loc_2151_;
											loc_2138_ = loc_2152_;
											loc_2137_ = -1;
											loc_2131_ = 0;
										end
										if not (rt_not_equal_i32(loc_2153_, 0)) then
											loc_2150_ = loc_2140_;
											loc_2151_ = loc_2139_;
											loc_2152_ = loc_2138_;
											loc_2153_ = loc_2137_;
											loc_2140_ = loc_2136_;
											loc_2139_ = loc_2117_;
											loc_2138_ = loc_2150_;
											loc_2137_ = loc_2151_;
											loc_2136_ = loc_2152_;
											loc_2117_ = loc_2153_;
											repeat
												rt_yield_budget = rt_yield_budget - 1
												if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
												loc_2150_ = loc_2136_;
												loc_2151_ = loc_2139_;
												loc_2152_ = loc_2140_;
												loc_2153_ = loc_2135_;
												loc_2135_ = rt_load_i32_from_s8(loc_2102_, loc_2118_, 0);
												if rt_less_than_u32(bit32_or(loc_2135_ + -123, 0), -58) then
													loc_2136_ = loc_2153_;
													loc_2153_ = 0;
													loc_2139_ = 1;
												else
													loc_2136_ = loc_2153_;
													loc_2135_ = rt_load_i32_from_u8(loc_2102_, bit32_or(bit32_or(loc_2135_ + rt_multiply_i32(loc_2136_, 58), 0) + 10127, 0), 0);
													loc_2118_ = bit32_or(loc_2118_ + 1, 0);
													if rt_less_than_u32(rt_and_i32(bit32_or(loc_2135_ + -1, 0), 255), 8) then
														loc_2153_ = 1;
														loc_2139_ = 65535;
													else
														loc_2153_ = 0;
														loc_2139_ = 0;
													end
												end
												loc_2140_ = loc_2153_;
											until loc_2153_ == 0
											if rt_not_equal_i32(loc_2139_, 0) then
												loc_2136_ = 0;
												loc_2117_ = 7;
											else
												if rt_equal_i32(loc_2135_, 27) then
													loc_2152_ = loc_2139_;
													loc_2139_ = loc_2137_;
													loc_2137_ = loc_2117_;
													loc_2153_ = loc_2140_;
													loc_2140_ = loc_2138_;
													loc_2138_ = loc_2136_;
													if rt_greater_than_s32(loc_2129_, -1) then
														loc_2153_ = 1;
														loc_2136_ = 0;
														loc_2117_ = 9;
													else
														loc_2151_ = loc_2135_;
														loc_2135_ = 0;
														if rt_equal_i32(loc_2112_, 0) then
															loc_2153_ = 1;
															loc_2136_ = 1;
															loc_2117_ = 65535;
														else
															loc_2151_ = loc_2153_;
															loc_2153_ = 0;
															loc_2136_ = loc_2151_;
															loc_2117_ = loc_2152_;
														end
													end
												else
													loc_2152_ = loc_2139_;
													loc_2139_ = loc_2137_;
													loc_2137_ = loc_2117_;
													loc_2153_ = loc_2140_;
													loc_2140_ = loc_2138_;
													loc_2138_ = loc_2136_;
													if rt_equal_i32(loc_2135_, 0) then
														loc_2153_ = 1;
														loc_2136_ = 0;
														loc_2117_ = 8;
													else
														if rt_less_than_s32(loc_2129_, 0) then
															loc_2117_ = loc_2152_;
															loc_2136_ = loc_2153_;
															loc_2152_ = loc_2109_;
															loc_2153_ = loc_2099_;
															if rt_not_equal_i32(loc_2112_, 0) then
																loc_2109_ = loc_2152_;
																loc_2152_[1](bit32_or(loc_2103_ + 40, 0), loc_2135_, loc_2113_, loc_2153_)
																loc_2153_ = 0;
															else
																loc_2150_ = loc_2117_;
																loc_2151_ = loc_2136_;
																loc_2152_, loc_2153_ = loc_2153_, loc_2152_;
																loc_2109_ = loc_2153_;
																loc_2153_ = 1;
																loc_2136_ = 0;
																loc_2117_ = 2;
																loc_2099_ = loc_2152_;
															end
														else
															loc_2117_ = loc_2152_;
															loc_2136_ = loc_2153_;
															loc_2152_ = loc_2109_;
															loc_2153_ = loc_2099_;
															if rt_not_equal_i32(loc_2112_, 0) then
																loc_2099_ = loc_2153_;
																loc_2109_ = loc_2152_;
																loc_2153_ = rt_load_i64(loc_2102_, bit32_or(loc_2114_ + rt_shift_left_i32(loc_2129_, 3), 0), 0);
																rt_store_i64(loc_2102_, loc_2103_, 40, loc_2153_)
																loc_2153_ = 0;
															else
																loc_2099_ = loc_2153_;
																loc_2109_ = loc_2152_;
																loc_2152_ = loc_2117_;
																loc_2153_ = loc_2136_;
																loc_2153_ = 1;
																loc_2136_ = 0;
																loc_2117_ = 0;
															end
														end
													end
												end
												if not (rt_not_equal_i32(loc_2153_, 0)) then
													loc_2153_ = loc_2129_;
													loc_2129_ = buffer_read_i32(loc_2102_[1], loc_2112_, 0);
													if rt_not_equal_i32(rt_and_i32(loc_2129_, 32), 0) then
														loc_2117_, loc_2137_ = loc_2137_, loc_2117_;
														loc_2137_, loc_2139_ = loc_2139_, loc_2137_;
														loc_2136_, loc_2138_ = loc_2138_, loc_2136_;
														loc_2138_, loc_2140_ = loc_2140_, loc_2138_;
														loc_2136_ = 0;
														loc_2117_ = 23;
													else
														loc_2153_ = loc_2135_;
														loc_2117_, loc_2137_ = loc_2137_, loc_2117_;
														loc_2137_, loc_2139_ = loc_2139_, loc_2137_;
														loc_2136_, loc_2138_ = loc_2138_, loc_2136_;
														loc_2138_, loc_2140_ = loc_2140_, loc_2138_;
														loc_2141_ = rt_and_i32(loc_2111_, -65537);
														if rt_not_equal_i32(rt_and_i32(loc_2111_, 8192), 0) then
															loc_2142_ = loc_2117_;
															loc_2117_ = loc_2139_;
															loc_2139_ = loc_2137_;
															loc_2137_ = loc_2141_;
															loc_2143_ = loc_2136_;
															loc_2136_ = loc_2140_;
															loc_2140_ = loc_2138_;
															loc_2153_ = loc_2111_;
														else
															loc_2142_ = loc_2117_;
															loc_2117_ = loc_2139_;
															loc_2139_ = loc_2137_;
															loc_2137_ = loc_2141_;
															loc_2143_ = loc_2136_;
															loc_2136_ = loc_2140_;
															loc_2140_ = loc_2138_;
															loc_2152_ = loc_2141_;
															loc_2153_ = loc_2111_;
															loc_2141_ = loc_2153_;
														end
														loc_2138_ = rt_load_i32_from_u8(loc_2102_, bit32_or(loc_2118_ + -1, 0), 0);
														loc_2152_ = rt_extend_s8_to_i32(loc_2138_);
														loc_2111_ = rt_and_i32(loc_2152_, -45);
														if rt_equal_i32(rt_and_i32(loc_2138_, 15), 3) then
															loc_2153_ = loc_2152_;
														else
															loc_2151_ = loc_2111_;
															loc_2153_ = loc_2152_;
															loc_2111_ = loc_2152_;
														end
														if rt_not_equal_i32(loc_2143_, 0) then
															loc_2135_ = loc_2153_;
														else
															loc_2135_ = loc_2153_;
															loc_2152_ = loc_2111_;
															loc_2111_ = loc_2153_;
														end
														loc_2153_ = bit32_or(loc_2111_ + -65, 0);
														if (loc_2153_) >= 0 and (loc_2153_) < 56 then
															if (loc_2153_) < 28 then
																if (loc_2153_) < 14 then
																	if (loc_2153_) < 7 then
																		if (loc_2153_) < 3 then
																			if (loc_2153_) < 1 then
																				loc_2153_ = 3;
																			elseif (loc_2153_) > 1 then
																				loc_2153_ = loc_2133_;
																				loc_2133_ = rt_load_i64(loc_2102_, loc_2103_, 40);
																				if rt_equal_i32((rt_equal_i64_constant(loc_2133_, 0, 0) and 1 or 0), 0) then
																					loc_2151_ = loc_2142_;
																					loc_2152_ = loc_2103_;
																					loc_2153_ = loc_2143_;
																					rt_store_i32(loc_2102_, loc_2152_, 12, 0)
																					rt_store_i64_into_i32(loc_2102_, loc_2152_, 8, loc_2133_)
																					rt_store_i32(loc_2102_, loc_2152_, 40, bit32_or(loc_2152_ + 8, 0))
																					loc_2153_ = 0;
																					loc_2103_ = loc_2152_;
																					loc_2143_ = bit32_or(loc_2152_ + 8, 0);
																					loc_2142_ = -1;
																				else
																					loc_2150_ = loc_2103_;
																					loc_2151_ = loc_2142_;
																					loc_2152_ = loc_2143_;
																					loc_2153_ = loc_2135_;
																					loc_2153_ = 2;
																					loc_2103_ = loc_2150_;
																					loc_2135_ = 0;
																					loc_2143_ = loc_2152_;
																					loc_2142_ = loc_2151_;
																				end
																			else
																				loc_2153_ = 9;
																			end
																		elseif (loc_2153_) > 3 then
																			if (loc_2153_) < 5 then
																				loc_2153_ = 3;
																			elseif (loc_2153_) > 5 then
																				loc_2153_ = 3;
																			else
																				loc_2153_ = 3;
																			end
																		else
																			loc_2153_ = 9;
																		end
																	elseif (loc_2153_) > 7 then
																		if (loc_2153_) < 11 then
																			if (loc_2153_) < 9 then
																				loc_2153_ = 9;
																			elseif (loc_2153_) > 9 then
																				loc_2153_ = 9;
																			else
																				loc_2153_ = 9;
																			end
																		elseif (loc_2153_) > 11 then
																			if (loc_2153_) < 13 then
																				loc_2153_ = 9;
																			else
																				loc_2153_ = 9;
																			end
																		else
																			loc_2153_ = 9;
																		end
																	else
																		loc_2153_ = 9;
																	end
																elseif (loc_2153_) > 14 then
																	if (loc_2153_) < 21 then
																		if (loc_2153_) < 18 then
																			if (loc_2153_) < 16 then
																				loc_2153_ = 9;
																			elseif (loc_2153_) > 16 then
																				loc_2153_ = 9;
																			else
																				loc_2153_ = 9;
																			end
																		elseif (loc_2153_) > 18 then
																			if (loc_2153_) < 20 then
																				loc_2153_ = 9;
																			else
																				loc_2153_ = 9;
																			end
																		else
																			if rt_equal_i32(loc_2142_, 0) then
																				loc_2151_ = loc_2135_;
																				loc_2152_ = loc_2110_;
																				loc_2153_ = loc_2099_;
																				loc_2110_ = loc_2152_;
																				loc_2152_[1](loc_2112_, 32, loc_2130_, 0, loc_2141_, loc_2153_)
																				loc_2153_ = 1;
																				loc_2135_ = 0;
																			else
																				loc_2150_ = loc_2143_;
																				loc_2151_ = loc_2135_;
																				loc_2152_ = loc_2099_;
																				loc_2153_ = loc_2110_;
																				loc_2110_ = loc_2153_;
																				loc_2143_ = buffer_read_i32(loc_2102_[1], loc_2103_, 40);
																				loc_2153_ = 0;
																				loc_2135_ = loc_2151_;
																				loc_2099_ = loc_2152_;
																			end
																		end
																	elseif (loc_2153_) > 21 then
																		if (loc_2153_) < 25 then
																			if (loc_2153_) < 23 then
																				loc_2153_ = 9;
																			elseif (loc_2153_) > 23 then
																				loc_2153_ = 9;
																			else
																				loc_2153_ = 7;
																			end
																		elseif (loc_2153_) > 25 then
																			if (loc_2153_) < 27 then
																				loc_2153_ = 9;
																			else
																				loc_2153_ = 9;
																			end
																		else
																			loc_2153_ = 9;
																		end
																	else
																		loc_2153_ = 9;
																	end
																else
																	loc_2153_ = 9;
																end
															elseif (loc_2153_) > 28 then
																if (loc_2153_) < 42 then
																	if (loc_2153_) < 35 then
																		if (loc_2153_) < 32 then
																			if (loc_2153_) < 30 then
																				loc_2153_ = 9;
																			elseif (loc_2153_) > 30 then
																				loc_2153_ = 9;
																			else
																				loc_2153_ = 9;
																			end
																		elseif (loc_2153_) > 32 then
																			if (loc_2153_) < 34 then
																				loc_2153_ = 9;
																			else
																				loc_2153_ = loc_2135_;
																				loc_2135_ = rt_load_i32_from_u8(loc_2102_, loc_2103_, 40);
																				loc_2153_ = 2;
																			end
																		else
																			loc_2153_ = 3;
																		end
																	elseif (loc_2153_) > 35 then
																		if (loc_2153_) < 39 then
																			if (loc_2153_) < 37 then
																				loc_2153_ = 3;
																			elseif (loc_2153_) > 37 then
																				loc_2153_ = 3;
																			else
																				loc_2153_ = 3;
																			end
																		elseif (loc_2153_) > 39 then
																			if (loc_2153_) < 41 then
																				loc_2153_ = 4;
																			else
																				loc_2153_ = 9;
																			end
																		else
																			loc_2153_ = 9;
																		end
																	else
																		loc_2153_ = 4;
																	end
																elseif (loc_2153_) > 42 then
																	if (loc_2153_) < 49 then
																		if (loc_2153_) < 46 then
																			if (loc_2153_) < 44 then
																				loc_2153_ = 9;
																			elseif (loc_2153_) > 44 then
																				loc_2151_ = loc_2135_;
																				loc_2152_ = loc_2117_;
																				loc_2153_ = loc_2136_;
																				loc_2135_ = 0;
																				if (loc_2143_) >= 0 and (loc_2143_) < 8 then
																					if (loc_2143_) < 4 then
																						if (loc_2143_) < 2 then
																							if (loc_2143_) < 1 then
																								loc_2153_ = buffer_read_i32(loc_2102_[1], loc_2103_, 40);
																								rt_store_i32(loc_2102_, loc_2153_, 0, loc_2100_)
																								loc_2153_ = 10;
																								loc_2136_ = 1;
																								loc_2117_ = 65535;
																							else
																								loc_2153_ = buffer_read_i32(loc_2102_[1], loc_2103_, 40);
																								rt_store_i32(loc_2102_, loc_2153_, 0, loc_2100_)
																								loc_2153_ = 10;
																								loc_2136_ = 1;
																								loc_2117_ = 65535;
																							end
																						elseif (loc_2143_) > 2 then
																							loc_2153_ = buffer_read_i32(loc_2102_[1], loc_2103_, 40);
																							rt_store_i32_into_i16(loc_2102_, loc_2153_, 0, loc_2100_)
																							loc_2153_ = 10;
																							loc_2136_ = 1;
																							loc_2117_ = 65535;
																						else
																							loc_2153_ = buffer_read_i32(loc_2102_[1], loc_2103_, 40);
																							rt_store_i64(loc_2102_, loc_2153_, 0, rt_extend_s32_to_i64(loc_2100_))
																							loc_2153_ = 10;
																							loc_2136_ = 1;
																							loc_2117_ = 65535;
																						end
																					elseif (loc_2143_) > 4 then
																						if (loc_2143_) < 6 then
																							loc_2153_ = 10;
																							loc_2136_ = 1;
																							loc_2117_ = 65535;
																						elseif (loc_2143_) > 6 then
																							loc_2153_ = buffer_read_i32(loc_2102_[1], loc_2103_, 40);
																							rt_store_i64(loc_2102_, loc_2153_, 0, rt_extend_s32_to_i64(loc_2100_))
																							loc_2153_ = 10;
																							loc_2136_ = 1;
																							loc_2117_ = 65535;
																						else
																							loc_2153_ = buffer_read_i32(loc_2102_[1], loc_2103_, 40);
																							rt_store_i32(loc_2102_, loc_2153_, 0, loc_2100_)
																							loc_2153_ = 10;
																							loc_2136_ = 1;
																							loc_2117_ = 65535;
																						end
																					else
																						loc_2153_ = buffer_read_i32(loc_2102_[1], loc_2103_, 40);
																						rt_store_i32_into_i8(loc_2102_, loc_2153_, 0, loc_2100_)
																						loc_2153_ = 10;
																						loc_2136_ = 1;
																						loc_2117_ = 65535;
																					end
																				else
																					loc_2153_ = 10;
																					loc_2136_ = 1;
																					loc_2117_ = 65535;
																				end
																			else
																				loc_2151_ = loc_2105_;
																				loc_2153_ = loc_2140_;
																				loc_2105_ = loc_2151_;
																				loc_2152_ = buffer_read_i32(loc_2102_[1], 0, 27520);
																				loc_2153_ = loc_2099_;
																				loc_2140_ = loc_2151_[1](loc_2152_, loc_2153_)
																				loc_2153_ = 5;
																			end
																		elseif (loc_2153_) > 46 then
																			if (loc_2153_) < 48 then
																				loc_2153_ = loc_2111_;
																				loc_2153_ = 8;
																				if rt_greater_than_u32(loc_2142_, 8) then
																					loc_2152_ = loc_2141_;
																				else
																					loc_2151_ = loc_2142_;
																					loc_2152_ = loc_2141_;
																					loc_2142_ = loc_2153_;
																				end
																				loc_2153_ = 7;
																				loc_2141_ = rt_or_i32(loc_2152_, 8);
																				loc_2111_ = 120;
																			else
																				loc_2153_ = 9;
																			end
																		else
																			loc_2150_ = loc_2133_;
																			loc_2151_ = loc_2132_;
																			loc_2152_ = loc_2129_;
																			loc_2153_ = loc_2140_;
																			loc_2133_ = rt_load_i64(loc_2102_, loc_2103_, 40);
																			if rt_equal_i64_constant(loc_2133_, 0, 0) then
																				loc_2140_ = loc_2128_;
																			else
																				loc_2152_ = loc_2128_;
																				loc_2153_ = loc_2128_;
																				loc_2128_ = loc_2153_;
																				loc_2140_ = loc_2153_;
																				repeat
																					rt_yield_budget = rt_yield_budget - 1
																					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																					loc_2153_ = loc_2135_;
																					loc_2140_ = bit32_or(loc_2140_ + -1, 0);
																					rt_store_i32_into_i8(loc_2102_, loc_2140_, 0, rt_or_i32(rt_and_i32(rt_narrow_i64(loc_2133_), 7), 48))
																					loc_2153_ = (rt_greater_than_u64(loc_2133_, into_bits_i64(7, 0)) and 1 or 0);
																					loc_2135_ = loc_2153_;
																					loc_2133_ = rt_shift_right_u64(loc_2133_, 3);
																				until loc_2153_ == 0
																			end
																			loc_2129_ = 0;
																			loc_2132_ = 1032;
																			if rt_equal_i32(rt_and_i32(loc_2141_, 8), 0) then
																				loc_2153_ = 8;
																			else
																				loc_2153_ = loc_2135_;
																				loc_2153_ = bit32_or(loc_2121_ - loc_2140_, 0);
																				if rt_greater_than_s32(loc_2142_, loc_2153_) then
																					loc_2135_ = loc_2153_;
																				else
																					loc_2135_ = loc_2153_;
																					loc_2152_ = loc_2142_;
																					loc_2142_ = loc_2153_;
																				end
																				loc_2153_ = 8;
																			end
																		end
																	elseif (loc_2153_) > 49 then
																		if (loc_2153_) < 53 then
																			if (loc_2153_) < 51 then
																				loc_2152_ = loc_2140_;
																				loc_2153_ = loc_2135_;
																				loc_2140_ = buffer_read_i32(loc_2102_[1], loc_2103_, 40);
																				loc_2153_ = 1679;
																				if rt_not_equal_i32(loc_2140_, 0) then
																					loc_2135_ = loc_2140_;
																				else
																					loc_2135_ = loc_2140_;
																					loc_2152_ = loc_2140_;
																					loc_2140_ = loc_2153_;
																				end
																				loc_2153_ = 5;
																			elseif (loc_2153_) > 51 then
																				loc_2151_ = loc_2133_;
																				loc_2152_ = loc_2132_;
																				loc_2153_ = loc_2129_;
																				loc_2133_ = rt_load_i64(loc_2102_, loc_2103_, 40);
																				loc_2153_ = 6;
																				loc_2129_ = 0;
																				loc_2132_ = 1032;
																			else
																				loc_2153_ = 9;
																			end
																		elseif (loc_2153_) > 53 then
																			if (loc_2153_) < 55 then
																				loc_2153_ = 9;
																			else
																				loc_2153_ = 7;
																			end
																		else
																			loc_2153_ = 9;
																		end
																	else
																		loc_2153_ = 9;
																	end
																else
																	loc_2153_ = 9;
																end
															else
																loc_2153_ = 9;
															end
														else
															loc_2153_ = 9;
														end
														if (loc_2153_) >= 0 and (loc_2153_) < 10 then
															if (loc_2153_) < 5 then
																if (loc_2153_) < 2 then
																	if (loc_2153_) < 1 then
																		loc_2151_ = loc_2111_;
																		loc_2152_ = loc_2140_;
																		loc_2153_ = loc_2135_;
																		loc_2152_ = loc_2136_;
																		loc_2151_ = loc_2117_;
																		loc_2135_ = 0;
																		loc_2140_ = loc_2143_;
																		loc_2153_ = loc_2143_;
																		repeat
																			rt_yield_budget = rt_yield_budget - 1
																			if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																			loc_2150_ = loc_2139_;
																			loc_2139_ = buffer_read_i32(loc_2102_[1], loc_2140_, 0);
																			if rt_equal_i32(loc_2139_, 0) then
																				loc_2150_ = 0;
																				loc_2151_ = 1;
																			else
																				loc_2152_ = loc_2099_;
																				loc_2139_ = loc_2107_[1](bit32_or(loc_2103_ + 4, 0), loc_2139_, loc_2152_)
																				if rt_less_than_s32(loc_2139_, 0) then
																					loc_2150_ = 0;
																					loc_2151_ = 2;
																				else
																					if rt_greater_than_u32(loc_2139_, bit32_or(loc_2142_ - loc_2135_, 0)) then
																						loc_2150_ = 0;
																						loc_2151_ = 1;
																					else
																						loc_2135_ = bit32_or(loc_2139_ + loc_2135_, 0);
																						loc_2140_ = bit32_or(loc_2140_ + 4, 0);
																						if rt_less_than_u32(loc_2135_, loc_2142_) then
																							loc_2150_ = 1;
																							loc_2151_ = 65535;
																						else
																							loc_2150_ = 0;
																							loc_2151_ = 0;
																						end
																					end
																				end
																			end
																			loc_2152_ = loc_2150_;
																		until loc_2150_ == 0
																		if (loc_2151_) >= 0 and (loc_2151_) < 2 then
																			if (loc_2151_) < 1 then
																				loc_2150_ = loc_2152_;
																				loc_2152_ = 0;
																				loc_2136_ = loc_2150_;
																				loc_2117_ = loc_2151_;
																			else
																				loc_2150_ = loc_2152_;
																				loc_2152_ = 0;
																				loc_2136_ = loc_2150_;
																				loc_2117_ = loc_2151_;
																			end
																		else
																			loc_2152_ = 1;
																			loc_2136_ = 0;
																			loc_2117_ = 24;
																		end
																		if rt_not_equal_i32(loc_2152_, 0) then
																			loc_2143_ = 4;
																		else
																			if rt_less_than_s32(loc_2135_, 0) then
																				loc_2151_ = loc_2153_;
																				loc_2152_ = loc_2117_;
																				loc_2153_ = loc_2136_;
																				loc_2143_ = 4;
																				loc_2136_ = 0;
																				loc_2117_ = 14;
																			else
																				loc_2151_ = loc_2153_;
																				loc_2152_ = loc_2117_;
																				loc_2153_ = loc_2136_;
																				loc_2150_ = loc_2099_;
																				loc_2110_[1](loc_2112_, 32, loc_2130_, loc_2135_, loc_2141_, loc_2150_)
																				if rt_not_equal_i32(loc_2135_, 0) then
																					loc_2117_ = loc_2152_;
																					loc_2136_ = loc_2153_;
																					loc_2152_ = loc_2140_;
																					loc_2153_ = loc_2151_;
																					loc_2140_ = 0;
																					repeat
																						rt_yield_budget = rt_yield_budget - 1
																						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																						loc_2150_ = loc_2139_;
																						loc_2151_ = loc_2117_;
																						loc_2152_ = loc_2136_;
																						loc_2139_ = buffer_read_i32(loc_2102_[1], loc_2153_, 0);
																						if rt_equal_i32(loc_2139_, 0) then
																							loc_2152_ = 0;
																							loc_2117_ = 1;
																						else
																							loc_2152_ = loc_2099_;
																							loc_2139_ = loc_2107_[1](bit32_or(loc_2103_ + 4, 0), loc_2139_, loc_2152_)
																							loc_2140_ = bit32_or(loc_2139_ + loc_2140_, 0);
																							if rt_greater_than_u32(loc_2140_, loc_2135_) then
																								loc_2152_ = 0;
																								loc_2117_ = 1;
																							else
																								loc_2152_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																								if not (rt_not_equal_i32(rt_and_i32(loc_2152_, 32), 0)) then
																									loc_2151_ = loc_2104_;
																									loc_2104_ = loc_2151_;
																									loc_2152_ = loc_2099_;
																									loc_2152_ = loc_2151_[1](bit32_or(loc_2103_ + 4, 0), loc_2139_, loc_2112_, loc_2152_)
																								end
																								loc_2153_ = bit32_or(loc_2153_ + 4, 0);
																								if rt_less_than_u32(loc_2140_, loc_2135_) then
																									loc_2152_ = 1;
																									loc_2117_ = 65535;
																								else
																									loc_2152_ = 0;
																									loc_2117_ = 0;
																								end
																							end
																						end
																						loc_2136_ = loc_2152_;
																					until loc_2152_ == 0
																					if rt_not_equal_i32(loc_2117_, 0) then
																						loc_2143_ = 0;
																					else
																						loc_2143_ = 0;
																					end
																				else
																					loc_2117_ = loc_2152_;
																					loc_2136_ = loc_2153_;
																					loc_2152_ = loc_2140_;
																					loc_2153_ = loc_2135_;
																					loc_2143_ = 0;
																					loc_2135_ = 0;
																					loc_2140_ = loc_2152_;
																				end
																			end
																		end
																	else
																		loc_2152_ = loc_2111_;
																		loc_2153_ = loc_2143_;
																		loc_2143_ = 0;
																	end
																elseif (loc_2153_) > 2 then
																	if (loc_2153_) < 4 then
																		loc_2153_ = loc_2135_;
																		loc_2135_ = (rt_less_than_s32(loc_2142_, 0) and 1 or 0);
																		if rt_not_equal_i32(rt_and_i32(loc_2131_, loc_2135_), 0) then
																			loc_2144_ = loc_2136_;
																			loc_2136_ = loc_2143_;
																			loc_2143_ = loc_2117_;
																			loc_2117_ = loc_2111_;
																			loc_2143_ = 4;
																			loc_2136_ = 0;
																			loc_2117_ = 15;
																		else
																			loc_2144_ = loc_2136_;
																			loc_2136_ = loc_2143_;
																			loc_2143_ = loc_2117_;
																			loc_2117_ = loc_2111_;
																			loc_2153_ = loc_2140_;
																			loc_2152_ = rt_load_f64(loc_2102_, loc_2103_, 40);
																			rt_store_i32(loc_2102_, loc_2103_, 92, 0)
																			if rt_greater_than_s64(rt_transmute_f64_to_i64(loc_2152_), into_bits_i64(4294967295, 4294967295)) then
																				loc_2140_ = loc_2123_;
																				loc_2123_ = loc_2137_;
																				loc_2148_ = loc_2132_;
																				loc_2132_ = loc_2135_;
																				loc_2135_ = loc_2143_;
																				loc_2149_ = loc_2131_;
																				loc_2131_ = loc_2136_;
																				loc_2136_ = loc_2144_;
																				loc_2144_ = loc_2103_;
																				loc_2150_ = loc_2138_;
																				loc_2151_ = loc_2139_;
																				loc_2139_ = loc_2117_;
																				loc_2153_ = loc_2099_;
																				if rt_equal_i32(rt_and_i32(loc_2141_, 2048), 0) then
																					loc_2147_ = rt_and_i32(loc_2141_, 1);
																					loc_2138_ = 1048;
																					loc_2146_ = 1043;
																					if not (rt_not_equal_i32(loc_2147_, 0)) then
																						loc_2145_ = loc_2138_;
																						loc_2138_ = loc_2146_;
																					end
																					loc_2137_ = loc_2147_;
																					loc_2117_ = (rt_equal_i32(loc_2147_, 0) and 1 or 0);
																				else
																					loc_2137_ = 1;
																					loc_2117_ = 0;
																					loc_2138_ = 1045;
																				end
																			else
																				loc_2140_ = loc_2123_;
																				loc_2123_ = loc_2137_;
																				loc_2148_ = loc_2132_;
																				loc_2132_ = loc_2135_;
																				loc_2135_ = loc_2143_;
																				loc_2149_ = loc_2131_;
																				loc_2131_ = loc_2136_;
																				loc_2136_ = loc_2144_;
																				loc_2144_ = loc_2103_;
																				loc_2150_ = loc_2138_;
																				loc_2151_ = loc_2139_;
																				loc_2139_ = loc_2117_;
																				loc_2153_ = loc_2099_;
																				loc_2152_ = rt_negate_f64(loc_2152_);
																				loc_2137_ = 1;
																				loc_2117_ = 0;
																				loc_2138_ = 1042;
																			end
																			if rt_less_than_f64(loc_2152_, from_bits_f64(0, 2146435072) --[[ inf_f64 ]]) then
																				loc_2153_ = loc_2108_[1](loc_2152_, bit32_or(loc_2144_ + 92, 0), loc_2153_)
																				loc_2143_ = rt_add_f64(loc_2153_, loc_2153_);
																				if rt_equal_f64(loc_2143_, 0) then
																					loc_2111_ = rt_or_i32(loc_2139_, 32);
																					if rt_equal_i32(loc_2111_, 97) then
																						loc_2153_ = 1;
																					else
																						loc_2152_ = loc_2129_;
																						loc_2153_ = loc_2131_;
																						loc_2129_ = 6;
																						if rt_not_equal_i32(loc_2132_, 0) then
																							loc_2153_ = loc_2142_;
																						else
																							loc_2152_ = loc_2129_;
																							loc_2153_ = loc_2142_;
																							loc_2129_ = loc_2153_;
																						end
																						loc_2131_ = buffer_read_i32(loc_2102_[1], loc_2144_, 92);
																						loc_2153_ = 0;
																					end
																				else
																					loc_2151_ = buffer_read_i32(loc_2102_[1], loc_2144_, 92);
																					rt_store_i32(loc_2102_, loc_2144_, 92, bit32_or(loc_2151_ + -1, 0))
																					loc_2111_ = rt_or_i32(loc_2139_, 32);
																					if rt_not_equal_i32(loc_2111_, 97) then
																						loc_2149_ = loc_2129_;
																						loc_2150_ = loc_2131_;
																						loc_2152_ = loc_2143_;
																						loc_2153_ = loc_2142_;
																						loc_2131_ = bit32_or(loc_2151_ + -29, 0);
																						rt_store_i32(loc_2102_, loc_2144_, 92, loc_2131_)
																						loc_2129_ = 6;
																						if rt_not_equal_i32(loc_2132_, 0) then
																							loc_2142_ = loc_2153_;
																						else
																							loc_2142_ = loc_2153_;
																							loc_2151_ = loc_2129_;
																							loc_2129_ = loc_2153_;
																						end
																						loc_2153_ = 0;
																						loc_2143_ = rt_multiply_f64(loc_2152_, 2.68435456e8);
																					else
																						loc_2149_ = loc_2129_;
																						loc_2150_ = loc_2131_;
																						loc_2152_ = loc_2143_;
																						loc_2153_ = loc_2151_;
																						loc_2151_ = loc_2142_;
																						loc_2153_ = 1;
																						loc_2131_ = loc_2150_;
																						loc_2129_ = loc_2149_;
																						loc_2142_ = loc_2151_;
																						loc_2143_ = loc_2152_;
																					end
																				end
																				if rt_not_equal_i32(loc_2153_, 0) then
																					loc_2129_ = bit32_or(loc_2138_ + rt_and_i32(rt_shift_right_s32(rt_shift_left_i32(loc_2139_, 26), 31), 9), 0);
																					if not (rt_greater_than_u32(loc_2142_, 11)) then
																						loc_2138_ = loc_2143_;
																						loc_2143_ = bit32_or(12 - loc_2142_, 0);
																						loc_2135_ = rt_and_i32(loc_2143_, 7);
																						if rt_not_equal_i32(loc_2135_, 0) then
																							loc_2136_ = bit32_or(loc_2142_ + -12, 0);
																							loc_2143_ = 1.6e1;
																							repeat
																								rt_yield_budget = rt_yield_budget - 1
																								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																								loc_2136_ = bit32_or(loc_2136_ + 1, 0);
																								loc_2132_ = bit32_or(loc_2135_ + -1, 0);
																								loc_2135_ = loc_2132_;
																								loc_2143_ = rt_multiply_f64(loc_2143_, 1.6e1);
																							until loc_2132_ == 0
																							loc_2136_ = bit32_or(0 - loc_2136_, 0);
																						else
																							loc_2136_ = loc_2135_;
																							loc_2136_ = loc_2143_;
																							loc_2143_ = 1.6e1;
																						end
																						if not (rt_greater_than_u32(loc_2142_, 4)) then
																							repeat
																								rt_yield_budget = rt_yield_budget - 1
																								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																								loc_2135_ = bit32_or(loc_2136_ + -8, 0);
																								loc_2136_ = loc_2135_;
																								loc_2143_ = rt_multiply_f64(rt_multiply_f64(rt_multiply_f64(rt_multiply_f64(rt_multiply_f64(rt_multiply_f64(rt_multiply_f64(rt_multiply_f64(loc_2143_, 1.6e1), 1.6e1), 1.6e1), 1.6e1), 1.6e1), 1.6e1), 1.6e1), 1.6e1);
																							until loc_2135_ == 0
																						end
																						loc_2136_ = rt_load_i32_from_u8(loc_2102_, loc_2129_, 0);
																						if rt_not_equal_i32(loc_2136_, 45) then
																							loc_2143_ = rt_subtract_f64(rt_add_f64(loc_2138_, loc_2143_), loc_2143_);
																						else
																							loc_2143_ = rt_negate_f64(rt_add_f64(loc_2143_, rt_subtract_f64(rt_negate_f64(loc_2138_), loc_2143_)));
																						end
																					end
																					loc_2138_ = buffer_read_i32(loc_2102_[1], loc_2144_, 92);
																					if rt_equal_i32(loc_2138_, 0) then
																						rt_store_i32_into_i8(loc_2102_, loc_2144_, 63, 48)
																						loc_2123_ = loc_2140_;
																					else
																						loc_2136_ = loc_2140_;
																						loc_2140_ = loc_2119_;
																						loc_2119_ = loc_2140_;
																						loc_2123_ = loc_2136_;
																						loc_2136_ = rt_shift_right_s32(loc_2138_, 31);
																						loc_2136_ = bit32_or(rt_exclusive_or_i32(loc_2138_, loc_2136_) - loc_2136_, 0);
																						repeat
																							rt_yield_budget = rt_yield_budget - 1
																							if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																							loc_2135_ = loc_2136_;
																							loc_2140_ = bit32_or(loc_2140_ + -1, 0);
																							loc_2132_ = rt_divide_u32(loc_2135_, 10);
																							rt_store_i32_into_i8(loc_2102_, loc_2140_, 0, rt_or_i32(bit32_or(loc_2135_ - rt_multiply_i32(loc_2132_, 10), 0), 48))
																							loc_2136_ = loc_2132_;
																						until not (rt_equal_i32((rt_less_than_u32(loc_2135_, 10) and 1 or 0), 0))
																					end
																					loc_2131_ = bit32_or(loc_2140_ + -2, 0);
																					rt_store_i32_into_i8(loc_2102_, loc_2131_, 0, bit32_or(loc_2139_ + 15, 0))
																					loc_2139_ = rt_and_i32(loc_2139_, 32);
																					loc_2137_ = rt_or_i32(loc_2137_, 2);
																					loc_2136_ = bit32_or(loc_2140_ + -1, 0);
																					loc_2140_ = 45;
																					loc_2135_ = 43;
																					if not (rt_less_than_s32(loc_2138_, 0)) then
																						loc_2140_ = loc_2135_;
																					end
																					rt_store_i32_into_i8(loc_2102_, loc_2136_, 0, loc_2140_)
																					loc_2103_ = loc_2144_;
																					loc_2140_ = bit32_or(loc_2144_ + 64, 0);
																					loc_2144_ = rt_and_i32((rt_equal_i32(rt_and_i32(loc_2141_, 8), 0) and 1 or 0), (rt_less_than_s32(loc_2142_, 1) and 1 or 0));
																					repeat
																						rt_yield_budget = rt_yield_budget - 1
																						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																						loc_2135_ = loc_2143_;
																						loc_2136_ = rt_saturate_f64_to_s32(loc_2135_);
																						loc_2143_ = rt_load_i32_from_u8(loc_2102_, bit32_or(loc_2136_ + 10656, 0), 0);
																						rt_store_i32_into_i8(loc_2102_, loc_2140_, 0, rt_or_i32(loc_2143_, loc_2139_))
																						loc_2143_ = bit32_or(loc_2140_ + 1, 0);
																						loc_2136_ = rt_multiply_f64(rt_subtract_f64(loc_2135_, rt_convert_s32_to_f64(loc_2136_)), 1.6e1);
																						if rt_not_equal_i32(bit32_or(loc_2143_ - bit32_or(loc_2103_ + 64, 0), 0), 1) then
																							loc_2140_, loc_2143_ = loc_2143_, loc_2140_;
																						else
																							loc_2140_, loc_2143_ = loc_2143_, loc_2140_;
																							if not (rt_not_equal_i32(rt_and_i32(loc_2144_, (rt_equal_f64(loc_2136_, 0) and 1 or 0)), 0)) then
																								rt_store_i32_into_i8(loc_2102_, loc_2143_, 1, 46)
																								loc_2140_ = bit32_or(loc_2143_ + 2, 0);
																							end
																						end
																						loc_2143_ = loc_2136_;
																					until not (rt_not_equal_f64(loc_2136_, 0))
																					loc_2132_ = bit32_or(loc_2119_ - loc_2131_, 0);
																					loc_2135_ = bit32_or(loc_2132_ + loc_2137_, 0);
																					if rt_greater_than_s32(loc_2142_, bit32_or(2147483645 - loc_2135_, 0)) then
																						loc_2143_ = 4;
																						loc_2136_ = 0;
																						loc_2117_ = 20;
																					else
																						loc_2143_ = loc_2138_;
																						loc_2144_ = loc_2139_;
																						loc_2140_ = bit32_or(loc_2140_ - bit32_or(loc_2103_ + 64, 0), 0);
																						loc_2138_ = bit32_or(loc_2142_ + 2, 0);
																						if rt_less_than_s32(bit32_or(loc_2140_ + -2, 0), loc_2142_) then
																							loc_2143_ = loc_2140_;
																							loc_2144_ = loc_2135_;
																							loc_2135_ = loc_2130_;
																						else
																							loc_2139_ = loc_2138_;
																							loc_2143_ = loc_2140_;
																							loc_2144_ = loc_2135_;
																							loc_2135_ = loc_2130_;
																							loc_2138_ = loc_2140_;
																						end
																						if rt_not_equal_i32(loc_2142_, 0) then
																							loc_2139_ = loc_2143_;
																						else
																							loc_2139_ = loc_2143_;
																							loc_2140_ = loc_2138_;
																							loc_2138_ = loc_2143_;
																						end
																						loc_2144_ = bit32_or(loc_2138_ + loc_2144_, 0);
																						loc_2143_ = rt_and_i32(loc_2141_, 73728);
																						if not (rt_not_equal_i32(loc_2143_, 0)) then
																							if not (rt_less_than_equal_s32(loc_2135_, loc_2144_)) then
																								loc_2141_ = bit32_or(loc_2135_ - loc_2144_, 0);
																								loc_2142_ = (rt_less_than_u32(loc_2141_, 256) and 1 or 0);
																								loc_2136_ = 256;
																								if rt_not_equal_i32(loc_2142_, 0) then
																									loc_2140_ = loc_2141_;
																								else
																									loc_2140_ = loc_2141_;
																									loc_2141_ = loc_2136_;
																								end
																								if not (rt_equal_i32(loc_2141_, 0)) then
																									rt_memory_fill(loc_2102_, bit32_or(loc_2103_ + 608, 0), 32, loc_2141_)
																								end
																								if not (rt_not_equal_i32(loc_2142_, 0)) then
																									repeat
																										rt_yield_budget = rt_yield_budget - 1
																										if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																										loc_2136_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																										if not (rt_not_equal_i32(rt_and_i32(loc_2136_, 32), 0)) then
																											loc_2130_ = loc_2104_;
																											loc_2104_ = loc_2130_;
																											loc_2136_ = loc_2099_;
																											loc_2136_ = loc_2130_[1](bit32_or(loc_2103_ + 608, 0), 256, loc_2112_, loc_2136_)
																										end
																										loc_2136_ = bit32_or(loc_2140_ + -256, 0);
																										loc_2140_ = loc_2136_;
																									until not (rt_greater_than_u32(loc_2136_, 255))
																								end
																								loc_2136_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																								if not (rt_not_equal_i32(rt_and_i32(loc_2136_, 32), 0)) then
																									loc_2130_ = loc_2104_;
																									loc_2104_ = loc_2130_;
																									loc_2136_ = loc_2099_;
																									loc_2140_ = loc_2130_[1](bit32_or(loc_2103_ + 608, 0), loc_2140_, loc_2112_, loc_2136_)
																								end
																							end
																						end
																						loc_2140_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																						if not (rt_not_equal_i32(rt_and_i32(loc_2140_, 32), 0)) then
																							loc_2136_ = loc_2104_;
																							loc_2104_ = loc_2136_;
																							loc_2140_ = loc_2099_;
																							loc_2140_ = loc_2136_[1](loc_2129_, loc_2137_, loc_2112_, loc_2140_)
																						end
																						if not (rt_not_equal_i32(loc_2143_, 65536)) then
																							if not (rt_less_than_equal_s32(loc_2135_, loc_2144_)) then
																								loc_2140_ = loc_2137_;
																								loc_2137_ = bit32_or(loc_2135_ - loc_2144_, 0);
																								loc_2142_ = (rt_less_than_u32(loc_2137_, 256) and 1 or 0);
																								loc_2136_ = 256;
																								if rt_not_equal_i32(loc_2142_, 0) then
																									loc_2140_ = loc_2137_;
																								else
																									loc_2140_ = loc_2137_;
																									loc_2137_ = loc_2136_;
																								end
																								if not (rt_equal_i32(loc_2137_, 0)) then
																									rt_memory_fill(loc_2102_, bit32_or(loc_2103_ + 608, 0), 48, loc_2137_)
																								end
																								if not (rt_not_equal_i32(loc_2142_, 0)) then
																									repeat
																										rt_yield_budget = rt_yield_budget - 1
																										if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																										loc_2136_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																										if not (rt_not_equal_i32(rt_and_i32(loc_2136_, 32), 0)) then
																											loc_2130_ = loc_2104_;
																											loc_2104_ = loc_2130_;
																											loc_2136_ = loc_2099_;
																											loc_2136_ = loc_2130_[1](bit32_or(loc_2103_ + 608, 0), 256, loc_2112_, loc_2136_)
																										end
																										loc_2136_ = bit32_or(loc_2140_ + -256, 0);
																										loc_2140_ = loc_2136_;
																									until not (rt_greater_than_u32(loc_2136_, 255))
																								end
																								loc_2136_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																								if not (rt_not_equal_i32(rt_and_i32(loc_2136_, 32), 0)) then
																									loc_2130_ = loc_2104_;
																									loc_2104_ = loc_2130_;
																									loc_2136_ = loc_2099_;
																									loc_2140_ = loc_2130_[1](bit32_or(loc_2103_ + 608, 0), loc_2140_, loc_2112_, loc_2136_)
																								end
																							end
																						end
																						loc_2140_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																						if not (rt_not_equal_i32(rt_and_i32(loc_2140_, 32), 0)) then
																							loc_2136_ = loc_2104_;
																							loc_2104_ = loc_2136_;
																							loc_2140_ = loc_2099_;
																							loc_2140_ = loc_2136_[1](bit32_or(loc_2103_ + 64, 0), loc_2139_, loc_2112_, loc_2140_)
																						end
																						loc_2140_ = bit32_or(loc_2138_ - loc_2139_, 0);
																						if not (rt_less_than_s32(loc_2140_, 1)) then
																							loc_2139_ = (rt_less_than_u32(loc_2140_, 256) and 1 or 0);
																							loc_2136_ = 256;
																							if rt_not_equal_i32(loc_2139_, 0) then
																								loc_2138_ = loc_2140_;
																							else
																								loc_2138_ = loc_2140_;
																								loc_2138_ = loc_2136_;
																							end
																							if not (rt_equal_i32(loc_2138_, 0)) then
																								rt_memory_fill(loc_2102_, bit32_or(loc_2103_ + 608, 0), 48, loc_2138_)
																							end
																							if not (rt_not_equal_i32(loc_2139_, 0)) then
																								repeat
																									rt_yield_budget = rt_yield_budget - 1
																									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																									loc_2136_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																									if not (rt_not_equal_i32(rt_and_i32(loc_2136_, 32), 0)) then
																										loc_2130_ = loc_2104_;
																										loc_2104_ = loc_2130_;
																										loc_2136_ = loc_2099_;
																										loc_2136_ = loc_2130_[1](bit32_or(loc_2103_ + 608, 0), 256, loc_2112_, loc_2136_)
																									end
																									loc_2136_ = bit32_or(loc_2140_ + -256, 0);
																									loc_2140_ = loc_2136_;
																								until not (rt_greater_than_u32(loc_2136_, 255))
																							end
																							loc_2136_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																							if not (rt_not_equal_i32(rt_and_i32(loc_2136_, 32), 0)) then
																								loc_2130_ = loc_2104_;
																								loc_2104_ = loc_2130_;
																								loc_2136_ = loc_2099_;
																								loc_2140_ = loc_2130_[1](bit32_or(loc_2103_ + 608, 0), loc_2140_, loc_2112_, loc_2136_)
																							end
																						end
																						loc_2140_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																						if not (rt_not_equal_i32(rt_and_i32(loc_2140_, 32), 0)) then
																							loc_2136_ = loc_2104_;
																							loc_2104_ = loc_2136_;
																							loc_2140_ = loc_2099_;
																							loc_2140_ = loc_2136_[1](loc_2131_, loc_2132_, loc_2112_, loc_2140_)
																						end
																						if not (rt_not_equal_i32(loc_2143_, 8192)) then
																							if not (rt_less_than_equal_s32(loc_2135_, loc_2144_)) then
																								loc_2143_ = loc_2139_;
																								loc_2140_ = bit32_or(loc_2135_ - loc_2144_, 0);
																								loc_2139_ = (rt_less_than_u32(loc_2140_, 256) and 1 or 0);
																								loc_2136_ = 256;
																								if rt_not_equal_i32(loc_2139_, 0) then
																									loc_2143_ = loc_2140_;
																								else
																									loc_2143_ = loc_2140_;
																									loc_2140_ = loc_2136_;
																								end
																								if not (rt_equal_i32(loc_2140_, 0)) then
																									rt_memory_fill(loc_2102_, bit32_or(loc_2103_ + 608, 0), 32, loc_2140_)
																								end
																								if not (rt_not_equal_i32(loc_2139_, 0)) then
																									repeat
																										rt_yield_budget = rt_yield_budget - 1
																										if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																										loc_2140_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																										if not (rt_not_equal_i32(rt_and_i32(loc_2140_, 32), 0)) then
																											loc_2136_ = loc_2104_;
																											loc_2104_ = loc_2136_;
																											loc_2140_ = loc_2099_;
																											loc_2140_ = loc_2136_[1](bit32_or(loc_2103_ + 608, 0), 256, loc_2112_, loc_2140_)
																										end
																										loc_2140_ = bit32_or(loc_2143_ + -256, 0);
																										loc_2143_ = loc_2140_;
																									until not (rt_greater_than_u32(loc_2140_, 255))
																								end
																								loc_2140_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																								if not (rt_not_equal_i32(rt_and_i32(loc_2140_, 32), 0)) then
																									loc_2136_ = loc_2104_;
																									loc_2104_ = loc_2136_;
																									loc_2140_ = loc_2099_;
																									loc_2143_ = loc_2136_[1](bit32_or(loc_2103_ + 608, 0), loc_2143_, loc_2112_, loc_2140_)
																								end
																							end
																						end
																						if rt_greater_than_s32(loc_2135_, loc_2144_) then
																							loc_2130_ = loc_2135_;
																							loc_2140_ = loc_2144_;
																						else
																							loc_2130_ = loc_2135_;
																							loc_2140_ = loc_2144_;
																							loc_2143_ = loc_2135_;
																							loc_2135_ = loc_2144_;
																						end
																						loc_2143_ = 4;
																						loc_2136_ = 1;
																						loc_2117_ = 65535;
																					end
																				else
																					loc_2146_ = (rt_less_than_s32(loc_2131_, 0) and 1 or 0);
																					loc_2151_ = bit32_or(loc_2144_ + 96, 0);
																					loc_2153_ = 0;
																					loc_2152_ = 288;
																					if rt_not_equal_i32(loc_2146_, 0) then
																						loc_2103_ = loc_2144_;
																						loc_2144_ = loc_2136_;
																						loc_2145_ = loc_2138_;
																						loc_2147_ = loc_2143_;
																						loc_2143_ = loc_2135_;
																						loc_2148_ = loc_2139_;
																						loc_2139_ = loc_2152_;
																						loc_2149_ = loc_2132_;
																						loc_2150_ = loc_2111_;
																						loc_2111_ = loc_2117_;
																						loc_2117_ = loc_2137_;
																						loc_2137_ = loc_2123_;
																						loc_2123_ = loc_2140_;
																						loc_2140_ = loc_2151_;
																						loc_2151_ = loc_2131_;
																						loc_2152_ = loc_2129_;
																					else
																						loc_2103_ = loc_2144_;
																						loc_2144_ = loc_2136_;
																						loc_2145_ = loc_2138_;
																						loc_2147_ = loc_2143_;
																						loc_2143_ = loc_2135_;
																						loc_2148_ = loc_2139_;
																						loc_2139_ = loc_2152_;
																						loc_2149_ = loc_2132_;
																						loc_2150_ = loc_2111_;
																						loc_2111_ = loc_2117_;
																						loc_2117_ = loc_2137_;
																						loc_2137_ = loc_2123_;
																						loc_2123_ = loc_2140_;
																						loc_2140_ = loc_2151_;
																						loc_2151_ = loc_2131_;
																						loc_2152_ = loc_2129_;
																						loc_2153_ = loc_2139_;
																					end
																					loc_2132_ = bit32_or(loc_2140_ + loc_2153_, 0);
																					loc_2153_ = loc_2132_;
																					repeat
																						rt_yield_budget = rt_yield_budget - 1
																						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																						loc_2140_ = rt_saturate_f64_to_u32(loc_2147_);
																						rt_store_i32(loc_2102_, loc_2153_, 0, loc_2140_)
																						loc_2149_ = loc_2140_;
																						loc_2153_ = bit32_or(loc_2153_ + 4, 0);
																						loc_2140_ = rt_multiply_f64(rt_subtract_f64(loc_2147_, rt_convert_u32_to_f64(loc_2140_)), 1e9);
																						loc_2147_ = loc_2140_;
																					until not (rt_not_equal_f64(loc_2140_, 0))
																					if rt_greater_than_equal_s32(loc_2151_, 1) then
																						loc_2139_ = loc_2132_;
																						repeat
																							rt_yield_budget = rt_yield_budget - 1
																							if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																							loc_2149_ = 29;
																							if rt_less_than_u32(loc_2151_, 29) then
																								loc_2149_, loc_2151_ = loc_2151_, loc_2149_;
																								loc_2151_, loc_2153_ = loc_2153_, loc_2151_;
																							else
																								loc_2149_, loc_2151_ = loc_2151_, loc_2149_;
																								loc_2151_, loc_2153_ = loc_2153_, loc_2151_;
																								loc_2149_ = loc_2153_;
																							end
																							loc_2153_ = bit32_or(loc_2151_ + -4, 0);
																							if not (rt_less_than_u32(loc_2153_, loc_2139_)) then
																								loc_2140_ = loc_2149_;
																								loc_2149_ = loc_2133_;
																								loc_2149_ = loc_2140_;
																								loc_2133_ = into_bits_i64(0, 0);
																								loc_2140_ = rt_widen_i32(loc_2140_);
																								repeat
																									rt_yield_budget = rt_yield_budget - 1
																									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																									loc_2136_ = loc_2139_;
																									loc_2139_ = loc_2134_;
																									loc_2139_ = rt_load_i64_from_u32(loc_2102_, loc_2153_, 0);
																									loc_2134_ = rt_add_i64(rt_shift_left_i64(loc_2139_, loc_2140_), loc_2133_);
																									loc_2135_ = rt_divide_u64(loc_2134_, into_bits_i64(1000000000, 0));
																									rt_store_i64_into_i32(loc_2102_, loc_2153_, 0, rt_subtract_i64(loc_2134_, rt_multiply_i64(loc_2135_, into_bits_i64(1000000000, 0))))
																									loc_2138_ = bit32_or(loc_2153_ + -4, 0);
																									loc_2153_ = loc_2138_;
																									loc_2139_ = loc_2136_;
																									loc_2133_ = loc_2135_;
																								until not (rt_greater_than_equal_u32(loc_2138_, loc_2136_))
																								if not (rt_less_than_u64(loc_2134_, into_bits_i64(1000000000, 0))) then
																									loc_2139_ = bit32_or(loc_2139_ + -4, 0);
																									rt_store_i64_into_i32(loc_2102_, loc_2139_, 0, loc_2133_)
																								end
																							end
																							repeat
																								rt_yield_budget = rt_yield_budget - 1
																								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																								loc_2143_, loc_2153_ = loc_2153_, loc_2143_;
																								loc_2153_, loc_2144_ = loc_2144_, loc_2153_;
																								if rt_less_than_equal_u32(loc_2151_, loc_2139_) then
																									loc_2153_ = loc_2151_;
																									loc_2140_ = 0;
																									loc_2143_ = 1;
																								else
																									loc_2153_ = loc_2151_;
																									loc_2151_ = bit32_or(loc_2153_ + -4, 0);
																									loc_2144_ = buffer_read_i32(loc_2102_[1], loc_2151_, 0);
																									if rt_equal_i32(loc_2144_, 0) then
																										loc_2140_ = 1;
																										loc_2143_ = 65535;
																									else
																										loc_2140_ = 0;
																										loc_2143_ = 0;
																									end
																								end
																								loc_2144_ = loc_2140_;
																							until loc_2140_ == 0
																							if rt_not_equal_i32(loc_2143_, 0) then
																							end
																							loc_2151_ = buffer_read_i32(loc_2102_[1], loc_2103_, 92);
																							loc_2140_ = bit32_or(loc_2151_ - loc_2149_, 0);
																							rt_store_i32(loc_2102_, loc_2103_, 92, loc_2140_)
																							loc_2149_ = loc_2153_;
																							loc_2151_ = loc_2140_;
																						until not (rt_greater_than_s32(loc_2140_, 0))
																					else
																						loc_2149_ = loc_2153_;
																						loc_2139_ = loc_2132_;
																					end
																					if not (rt_greater_than_s32(loc_2151_, -1)) then
																						loc_2140_ = loc_2150_;
																						loc_2153_ = loc_2152_;
																						loc_2152_ = loc_2153_;
																						loc_2150_ = loc_2140_;
																						loc_2138_ = rt_divide_u32(bit32_or(loc_2153_ + 25, 0), 9);
																						loc_2153_ = bit32_or(loc_2138_ + 1, 0);
																						loc_2140_ = (rt_equal_i32(loc_2140_, 102) and 1 or 0);
																						repeat
																							rt_yield_budget = rt_yield_budget - 1
																							if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																							loc_2142_ = bit32_or(0 - loc_2151_, 0);
																							loc_2151_ = 9;
																							if rt_less_than_u32(loc_2142_, 9) then
																								loc_2136_ = loc_2132_;
																								loc_2137_, loc_2142_ = loc_2142_, loc_2137_;
																								loc_2139_, loc_2151_ = loc_2151_, loc_2139_;
																								loc_2151_, loc_2149_ = loc_2149_, loc_2151_;
																							else
																								loc_2136_ = loc_2132_;
																								loc_2138_ = loc_2142_;
																								loc_2142_ = loc_2137_;
																								loc_2139_, loc_2151_ = loc_2151_, loc_2139_;
																								loc_2151_, loc_2149_ = loc_2149_, loc_2151_;
																								loc_2137_ = loc_2139_;
																							end
																							if rt_less_than_u32(loc_2149_, loc_2151_) then
																								loc_2139_ = loc_2149_;
																								loc_2138_ = 0;
																								loc_2142_ = loc_2137_;
																								loc_2135_ = rt_exclusive_or_i32(rt_shift_left_i32(-1, loc_2137_), -1);
																								loc_2137_ = rt_shift_right_u32(1000000000, loc_2137_);
																								repeat
																									rt_yield_budget = rt_yield_budget - 1
																									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																									loc_2131_ = loc_2151_;
																									loc_2151_ = loc_2138_;
																									loc_2138_ = buffer_read_i32(loc_2102_[1], loc_2139_, 0);
																									rt_store_i32(loc_2102_, loc_2139_, 0, bit32_or(rt_shift_right_u32(loc_2138_, loc_2142_) + loc_2151_, 0))
																									loc_2151_ = loc_2131_;
																									loc_2132_ = bit32_or(loc_2139_ + 4, 0);
																									loc_2139_ = loc_2132_;
																									loc_2138_ = rt_multiply_i32(rt_and_i32(loc_2138_, loc_2135_), loc_2137_);
																								until not (rt_less_than_u32(loc_2132_, loc_2131_))
																								loc_2132_ = buffer_read_i32(loc_2102_[1], loc_2149_, 0);
																								loc_2139_ = 0;
																								loc_2135_ = 4;
																								if not (rt_not_equal_i32(loc_2132_, 0)) then
																									loc_2139_ = loc_2135_;
																								end
																								if not (rt_equal_i32(loc_2138_, 0)) then
																									rt_store_i32(loc_2102_, loc_2151_, 0, loc_2138_)
																									loc_2151_ = bit32_or(loc_2151_ + 4, 0);
																								end
																							else
																								loc_2135_ = buffer_read_i32(loc_2102_[1], loc_2149_, 0);
																								loc_2139_ = 0;
																								loc_2138_ = 4;
																								if rt_not_equal_i32(loc_2135_, 0) then
																									loc_2137_, loc_2142_ = loc_2142_, loc_2137_;
																								else
																									loc_2137_, loc_2142_ = loc_2142_, loc_2137_;
																									loc_2139_ = loc_2138_;
																								end
																							end
																							loc_2138_ = buffer_read_i32(loc_2102_[1], loc_2103_, 92);
																							loc_2138_ = bit32_or(loc_2138_ + loc_2142_, 0);
																							rt_store_i32(loc_2102_, loc_2103_, 92, loc_2138_)
																							loc_2149_ = bit32_or(loc_2149_ + loc_2139_, 0);
																							if rt_not_equal_i32(loc_2140_, 0) then
																								loc_2132_ = loc_2136_;
																								loc_2139_ = loc_2149_;
																							else
																								loc_2132_ = loc_2136_;
																								loc_2139_ = loc_2149_;
																								loc_2136_ = loc_2149_;
																							end
																							loc_2149_ = bit32_or(loc_2136_ + rt_shift_left_i32(loc_2153_, 2), 0);
																							if not (rt_greater_than_s32(rt_shift_right_s32(bit32_or(loc_2151_ - loc_2136_, 0), 2), loc_2153_)) then
																								loc_2149_ = loc_2151_;
																							end
																							loc_2151_ = loc_2138_;
																						until not (rt_less_than_s32(loc_2138_, 0))
																					end
																					loc_2140_ = 0;
																					if not (rt_greater_than_equal_u32(loc_2139_, loc_2149_)) then
																						loc_2153_ = loc_2151_;
																						loc_2151_ = loc_2140_;
																						loc_2151_ = buffer_read_i32(loc_2102_[1], loc_2139_, 0);
																						loc_2140_ = rt_multiply_i32(rt_shift_right_s32(bit32_or(loc_2132_ - loc_2139_, 0), 2), 9);
																						if not (rt_less_than_u32(loc_2151_, 10)) then
																							loc_2153_ = 10;
																							repeat
																								rt_yield_budget = rt_yield_budget - 1
																								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																								loc_2136_ = loc_2151_;
																								loc_2138_ = rt_multiply_i32(loc_2153_, 10);
																								loc_2153_ = loc_2138_;
																								loc_2151_ = loc_2136_;
																								loc_2140_ = bit32_or(loc_2140_ + 1, 0);
																							until not (rt_greater_than_equal_u32(loc_2136_, loc_2138_))
																						end
																					end
																					loc_2153_ = 0;
																					if rt_equal_i32(loc_2150_, 102) then
																						loc_2135_ = loc_2152_;
																						loc_2138_ = loc_2140_;
																					else
																						loc_2135_ = loc_2152_;
																						loc_2138_ = loc_2140_;
																						loc_2153_ = loc_2140_;
																					end
																					loc_2131_ = (rt_equal_i32(loc_2150_, 103) and 1 or 0);
																					loc_2150_ = bit32_or(bit32_or(loc_2152_ - loc_2153_, 0) - rt_and_i32((rt_not_equal_i32(loc_2135_, 0) and 1 or 0), loc_2131_), 0);
																					if not (rt_greater_than_equal_s32(loc_2150_, bit32_or(rt_multiply_i32(rt_shift_right_s32(bit32_or(loc_2149_ - loc_2132_, 0), 2), 9) + -9, 0))) then
																						loc_2152_ = loc_2151_;
																						loc_2151_ = loc_2142_;
																						loc_2153_ = loc_2146_;
																						loc_2146_ = loc_2137_;
																						loc_2151_ = bit32_or(loc_2103_ + 96, 0);
																						loc_2146_ = -4092;
																						loc_2152_ = -3804;
																						if rt_not_equal_i32(loc_2153_, 0) then
																							loc_2153_ = loc_2150_;
																							loc_2150_ = loc_2149_;
																						else
																							loc_2153_ = loc_2150_;
																							loc_2150_ = loc_2149_;
																							loc_2149_ = loc_2146_;
																							loc_2146_ = loc_2152_;
																						end
																						loc_2149_ = 10;
																						loc_2153_ = bit32_or(loc_2153_ + 9216, 0);
																						loc_2152_ = rt_divide_s32(loc_2153_, 9);
																						loc_2153_ = bit32_or(loc_2153_ - rt_multiply_i32(loc_2152_, 9), 0);
																						loc_2140_ = rt_shift_left_i32(loc_2152_, 2);
																						loc_2137_ = bit32_or(bit32_or(loc_2151_ + loc_2146_, 0) + loc_2140_, 0);
																						if not (rt_greater_than_s32(loc_2153_, 7)) then
																							loc_2151_ = loc_2153_;
																							loc_2153_ = loc_2149_;
																							loc_2149_ = 10;
																							loc_2152_ = bit32_or(8 - loc_2151_, 0);
																							loc_2153_ = rt_and_i32(loc_2152_, 7);
																							if not (rt_less_than_u32(bit32_or(loc_2151_ + -1, 0), 7)) then
																								loc_2151_ = loc_2149_;
																								loc_2149_ = 10;
																								loc_2152_ = rt_and_i32(loc_2152_, -8);
																								repeat
																									rt_yield_budget = rt_yield_budget - 1
																									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																									loc_2149_ = rt_multiply_i32(loc_2149_, 100000000);
																									loc_2151_ = bit32_or(loc_2152_ + -8, 0);
																									loc_2152_ = loc_2151_;
																								until loc_2151_ == 0
																							end
																							if not (rt_equal_i32(loc_2153_, 0)) then
																								repeat
																									rt_yield_budget = rt_yield_budget - 1
																									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																									loc_2149_ = rt_multiply_i32(loc_2149_, 10);
																									loc_2152_ = bit32_or(loc_2153_ + -1, 0);
																									loc_2153_ = loc_2152_;
																								until loc_2152_ == 0
																							end
																						end
																						loc_2151_ = buffer_read_i32(loc_2102_[1], loc_2137_, 0);
																						loc_2129_ = rt_divide_u32(loc_2151_, loc_2149_);
																						loc_2142_ = bit32_or(loc_2151_ - rt_multiply_i32(loc_2129_, loc_2149_), 0);
																						loc_2136_ = bit32_or(loc_2137_ + 4, 0);
																						loc_2153_ = loc_2129_;
																						if rt_not_equal_i32(loc_2142_, 0) then
																							loc_2153_ = 0;
																						else
																							if rt_equal_i32(loc_2136_, loc_2150_) then
																								loc_2153_ = 1;
																							else
																								loc_2153_ = 0;
																							end
																						end
																						if not (rt_not_equal_i32(loc_2153_, 0)) then
																							if rt_not_equal_i32(rt_and_i32(loc_2129_, 1), 0) then
																								loc_2152_ = loc_2136_;
																								loc_2136_ = loc_2147_;
																								loc_2147_ = loc_2146_;
																								loc_2146_ = loc_2140_;
																								loc_2153_ = 0;
																							else
																								loc_2152_ = loc_2136_;
																								loc_2153_ = loc_2147_;
																								loc_2147_ = loc_2146_;
																								loc_2146_ = loc_2140_;
																								loc_2136_ = 9.007199254740992e15;
																								if rt_not_equal_i32(loc_2149_, 1000000000) then
																									loc_2153_ = 1;
																								else
																									if rt_less_than_equal_u32(loc_2137_, loc_2139_) then
																										loc_2153_ = 1;
																									else
																										loc_2153_ = rt_load_i32_from_u8(loc_2102_, bit32_or(loc_2137_ + -4, 0), 0);
																										if rt_equal_i32(rt_and_i32(loc_2153_, 1), 0) then
																											loc_2153_ = 1;
																										else
																											loc_2153_ = 0;
																										end
																									end
																								end
																							end
																							if not (rt_not_equal_i32(loc_2153_, 0)) then
																								loc_2153_ = loc_2136_;
																								loc_2136_ = 9.007199254740994e15;
																							end
																							loc_2140_ = 5e-1;
																							loc_2129_ = 1e0;
																							loc_2153_ = 1.5e0;
																							if not (rt_equal_i32(loc_2152_, loc_2150_)) then
																								loc_2152_ = loc_2129_;
																								loc_2129_ = loc_2153_;
																							end
																							loc_2152_ = rt_shift_right_u32(loc_2149_, 1);
																							loc_2153_ = 1.5e0;
																							if not (rt_equal_i32(loc_2142_, loc_2152_)) then
																								loc_2129_ = loc_2153_;
																							end
																							if not (rt_less_than_u32(loc_2142_, loc_2152_)) then
																								loc_2140_ = loc_2129_;
																							end
																							if not (rt_not_equal_i32(loc_2111_, 0)) then
																								loc_2129_ = rt_load_i32_from_u8(loc_2102_, loc_2145_, 0);
																								if not (rt_not_equal_i32(loc_2129_, 45)) then
																									loc_2136_ = rt_negate_f64(loc_2136_);
																									loc_2140_ = rt_negate_f64(loc_2140_);
																								end
																							end
																							loc_2151_ = bit32_or(loc_2151_ - loc_2142_, 0);
																							rt_store_i32(loc_2102_, loc_2137_, 0, loc_2151_)
																							if not (rt_equal_f64(rt_add_f64(loc_2136_, loc_2140_), loc_2136_)) then
																								loc_2140_ = loc_2138_;
																								loc_2151_ = bit32_or(loc_2151_ + loc_2149_, 0);
																								rt_store_i32(loc_2102_, loc_2137_, 0, loc_2151_)
																								if rt_less_than_u32(loc_2151_, 1000000000) then
																									loc_2149_ = loc_2146_;
																									loc_2151_ = loc_2147_;
																								else
																									loc_2149_ = loc_2146_;
																									loc_2146_ = loc_2137_;
																									loc_2151_ = loc_2147_;
																									loc_2147_ = loc_2120_;
																									loc_2120_ = loc_2147_;
																									loc_2151_ = bit32_or(loc_2147_ + bit32_or(loc_2151_ + loc_2149_, 0), 0);
																									repeat
																										rt_yield_budget = rt_yield_budget - 1
																										if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																										rt_store_i32(loc_2102_, bit32_or(loc_2151_ + 4, 0), 0, 0)
																										if not (rt_greater_than_equal_u32(loc_2151_, loc_2139_)) then
																											loc_2139_ = bit32_or(loc_2139_ + -4, 0);
																											rt_store_i32(loc_2102_, loc_2139_, 0, 0)
																										end
																										loc_2149_ = buffer_read_i32(loc_2102_[1], loc_2151_, 0);
																										loc_2149_ = bit32_or(loc_2149_ + 1, 0);
																										rt_store_i32(loc_2102_, loc_2151_, 0, loc_2149_)
																										loc_2151_ = bit32_or(loc_2151_ + -4, 0);
																									until not (rt_greater_than_u32(loc_2149_, 999999999))
																									loc_2137_ = bit32_or(loc_2151_ + 4, 0);
																								end
																								loc_2151_ = buffer_read_i32(loc_2102_[1], loc_2139_, 0);
																								loc_2138_ = rt_multiply_i32(rt_shift_right_s32(bit32_or(loc_2132_ - loc_2139_, 0), 2), 9);
																								if not (rt_less_than_u32(loc_2151_, 10)) then
																									loc_2149_ = 10;
																									repeat
																										rt_yield_budget = rt_yield_budget - 1
																										if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																										loc_2146_ = loc_2151_;
																										loc_2147_ = rt_multiply_i32(loc_2149_, 10);
																										loc_2149_ = loc_2147_;
																										loc_2151_ = loc_2146_;
																										loc_2138_ = bit32_or(loc_2138_ + 1, 0);
																									until not (rt_greater_than_equal_u32(loc_2146_, loc_2147_))
																								end
																							end
																						end
																						loc_2149_ = bit32_or(loc_2137_ + 4, 0);
																						if not (rt_greater_than_u32(loc_2150_, loc_2149_)) then
																							loc_2149_ = loc_2150_;
																						end
																					end
																					loc_2150_ = loc_2149_;
																					loc_2149_ = bit32_or(loc_2149_ - loc_2132_, 0);
																					repeat
																						rt_yield_budget = rt_yield_budget - 1
																						if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																						loc_2146_ = loc_2151_;
																						loc_2147_ = loc_2143_;
																						loc_2143_ = loc_2137_;
																						loc_2151_ = loc_2144_;
																						loc_2144_ = loc_2142_;
																						loc_2142_ = (rt_less_than_equal_u32(loc_2150_, loc_2139_) and 1 or 0);
																						if rt_not_equal_i32(loc_2142_, 0) then
																							loc_2137_ = loc_2150_;
																							loc_2151_ = loc_2149_;
																							loc_2147_ = 0;
																							loc_2143_ = 1;
																						else
																							loc_2137_ = loc_2150_;
																							loc_2151_ = loc_2149_;
																							loc_2150_ = bit32_or(loc_2137_ + -4, 0);
																							loc_2147_ = buffer_read_i32(loc_2102_[1], loc_2150_, 0);
																							loc_2149_ = bit32_or(loc_2151_ + -4, 0);
																							if rt_equal_i32(loc_2147_, 0) then
																								loc_2147_ = 1;
																								loc_2143_ = 65535;
																							else
																								loc_2147_ = 0;
																								loc_2143_ = 0;
																							end
																						end
																						loc_2144_ = loc_2147_;
																					until loc_2147_ == 0
																					if rt_not_equal_i32(loc_2143_, 0) then
																					end
																					if rt_not_equal_i32(loc_2131_, 0) then
																						loc_2150_ = rt_exclusive_or_i32(loc_2138_, -1);
																						loc_2149_ = -1;
																						loc_2147_ = 1;
																						if not (rt_not_equal_i32(loc_2135_, 0)) then
																							loc_2146_ = loc_2135_;
																							loc_2135_ = loc_2147_;
																						end
																						loc_2140_ = rt_and_i32((rt_greater_than_s32(loc_2135_, loc_2138_) and 1 or 0), (rt_greater_than_s32(loc_2138_, -5) and 1 or 0));
																						if not (rt_not_equal_i32(loc_2140_, 0)) then
																							loc_2150_ = loc_2149_;
																						end
																						loc_2150_ = bit32_or(loc_2150_ + loc_2135_, 0);
																						loc_2149_ = -1;
																						loc_2147_ = -2;
																						if not (rt_not_equal_i32(loc_2140_, 0)) then
																							loc_2149_ = loc_2147_;
																						end
																						loc_2136_ = bit32_or(loc_2149_ + loc_2148_, 0);
																						loc_2147_ = rt_and_i32(loc_2141_, 8);
																						if not (rt_not_equal_i32(loc_2147_, 0)) then
																							loc_2148_ = loc_2140_;
																							loc_2149_ = loc_2151_;
																							loc_2151_ = loc_2135_;
																							loc_2151_ = -9;
																							if not (rt_not_equal_i32(loc_2142_, 0)) then
																								loc_2148_ = loc_2142_;
																								loc_2142_ = buffer_read_i32(loc_2102_[1], bit32_or(loc_2137_ + -4, 0), 0);
																								if not (rt_equal_i32(loc_2142_, 0)) then
																									loc_2151_ = 0;
																									loc_2148_ = rt_remainder_u32(loc_2142_, 10);
																									loc_2147_ = loc_2148_;
																									if not (rt_not_equal_i32(loc_2148_, 0)) then
																										loc_2151_ = 0;
																										loc_2148_ = 10;
																										repeat
																											rt_yield_budget = rt_yield_budget - 1
																											if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																											loc_2146_ = loc_2142_;
																											loc_2151_ = bit32_or(loc_2151_ + -1, 0);
																											loc_2147_ = rt_multiply_i32(loc_2148_, 10);
																											loc_2148_ = loc_2147_;
																											loc_2142_ = loc_2146_;
																											loc_2147_ = rt_remainder_u32(loc_2146_, loc_2147_);
																											loc_2146_ = loc_2147_;
																										until not (rt_equal_i32(loc_2147_, 0))
																									end
																								end
																							end
																							loc_2140_ = rt_multiply_i32(rt_shift_right_s32(loc_2149_, 2), 9);
																							if rt_not_equal_i32(rt_and_i32(loc_2136_, -33), 70) then
																								loc_2147_ = 0;
																								loc_2151_ = bit32_or(bit32_or(bit32_or(loc_2138_ + loc_2140_, 0) + loc_2151_, 0) + -9, 0);
																								loc_2148_ = 0;
																								if rt_greater_than_s32(loc_2151_, 0) then
																									loc_2149_ = loc_2150_;
																								else
																									loc_2149_ = loc_2150_;
																									loc_2151_ = loc_2148_;
																								end
																								if rt_less_than_s32(loc_2149_, loc_2151_) then
																									loc_2135_ = loc_2151_;
																								else
																									loc_2135_ = loc_2151_;
																									loc_2150_ = loc_2151_;
																								end
																							else
																								loc_2147_ = 0;
																								loc_2151_ = bit32_or(bit32_or(loc_2140_ + loc_2151_, 0) + -9, 0);
																								loc_2148_ = 0;
																								if rt_greater_than_s32(loc_2151_, 0) then
																									loc_2149_ = loc_2150_;
																								else
																									loc_2149_ = loc_2150_;
																									loc_2151_ = loc_2148_;
																								end
																								if rt_less_than_s32(loc_2149_, loc_2151_) then
																									loc_2135_ = loc_2151_;
																								else
																									loc_2135_ = loc_2151_;
																									loc_2150_ = loc_2151_;
																								end
																							end
																						end
																					else
																						loc_2146_ = loc_2151_;
																						loc_2147_ = loc_2150_;
																						loc_2150_ = loc_2135_;
																						loc_2151_ = loc_2141_;
																						loc_2135_ = loc_2147_;
																						loc_2140_ = loc_2149_;
																						loc_2141_ = loc_2151_;
																						loc_2136_ = loc_2148_;
																						loc_2147_ = rt_and_i32(loc_2151_, 8);
																					end
																					loc_2146_ = rt_or_i32(loc_2150_, loc_2147_);
																					loc_2151_ = 2147483645;
																					loc_2149_ = 2147483646;
																					if rt_not_equal_i32(loc_2146_, 0) then
																						loc_2129_ = loc_2150_;
																					else
																						loc_2129_ = loc_2150_;
																						loc_2151_ = loc_2149_;
																					end
																					if rt_greater_than_s32(loc_2150_, loc_2151_) then
																						loc_2143_ = 4;
																						loc_2136_ = 0;
																						loc_2117_ = 16;
																					else
																						loc_2151_ = (rt_not_equal_i32(rt_and_i32(loc_2136_, -33), 70) and 1 or 0);
																						loc_2148_ = bit32_or(bit32_or(loc_2129_ + (rt_not_equal_i32(loc_2146_, 0) and 1 or 0), 0) + 1, 0);
																						if rt_not_equal_i32(loc_2151_, 0) then
																							loc_2149_ = loc_2144_;
																							loc_2144_ = loc_2146_;
																							loc_2146_ = loc_2119_;
																							loc_2150_ = loc_2136_;
																							loc_2136_ = loc_2143_;
																							loc_2143_ = loc_2151_;
																							loc_2151_ = loc_2135_;
																							loc_2135_ = loc_2111_;
																							loc_2111_ = loc_2147_;
																							loc_2147_ = loc_2117_;
																							if rt_not_equal_i32(loc_2138_, 0) then
																								loc_2119_ = loc_2146_;
																								loc_2151_ = rt_shift_right_s32(loc_2138_, 31);
																								loc_2135_ = bit32_or(rt_exclusive_or_i32(loc_2138_, loc_2151_) - loc_2151_, 0);
																								loc_2140_ = loc_2146_;
																								repeat
																									rt_yield_budget = rt_yield_budget - 1
																									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																									loc_2151_ = loc_2142_;
																									loc_2142_ = loc_2131_;
																									loc_2131_ = loc_2135_;
																									loc_2140_ = bit32_or(loc_2140_ + -1, 0);
																									loc_2151_ = rt_divide_u32(loc_2131_, 10);
																									rt_store_i32_into_i8(loc_2102_, loc_2140_, 0, rt_or_i32(bit32_or(loc_2131_ - rt_multiply_i32(loc_2151_, 10), 0), 48))
																									loc_2135_ = loc_2151_;
																									loc_2146_ = bit32_or(loc_2146_ + -1, 0);
																									loc_2142_ = loc_2151_;
																									loc_2117_ = (rt_greater_than_u32(loc_2131_, 9) and 1 or 0);
																									loc_2131_ = loc_2117_;
																								until loc_2117_ == 0
																							else
																								loc_2119_ = loc_2146_;
																								loc_2140_ = loc_2146_;
																							end
																							if not (rt_greater_than_s32(bit32_or(loc_2119_ - loc_2146_, 0), 1)) then
																								loc_2135_ = loc_2146_;
																								loc_2146_ = bit32_or(bit32_or(loc_2135_ - bit32_or(loc_2103_ + 52, 0), 0) + -10, 0);
																								loc_2140_ = bit32_or(loc_2140_ + bit32_or(loc_2127_ - loc_2135_, 0), 0);
																								if not (rt_equal_i32(loc_2146_, 0)) then
																									rt_memory_fill(loc_2102_, loc_2140_, 48, loc_2146_)
																								end
																							end
																							loc_2146_ = bit32_or(loc_2140_ + -2, 0);
																							rt_store_i32_into_i8(loc_2102_, loc_2146_, 0, loc_2150_)
																							loc_2117_ = bit32_or(loc_2140_ + -1, 0);
																							loc_2135_ = 45;
																							loc_2150_ = 43;
																							if not (rt_less_than_s32(loc_2138_, 0)) then
																								loc_2135_ = loc_2150_;
																							end
																							rt_store_i32_into_i8(loc_2102_, loc_2117_, 0, loc_2135_)
																							loc_2135_ = bit32_or(loc_2119_ - loc_2146_, 0);
																							if rt_greater_than_s32(loc_2135_, rt_exclusive_or_i32(loc_2148_, 2147483647)) then
																								loc_2149_ = 2;
																								loc_2136_ = 0;
																								loc_2117_ = 18;
																							else
																								loc_2117_ = loc_2136_;
																								loc_2136_ = loc_2149_;
																								loc_2149_ = 0;
																							end
																						else
																							loc_2149_ = loc_2144_;
																							loc_2144_ = loc_2146_;
																							loc_2146_ = loc_2119_;
																							loc_2150_ = loc_2136_;
																							loc_2136_ = loc_2143_;
																							loc_2143_ = loc_2151_;
																							loc_2151_ = loc_2135_;
																							loc_2135_ = loc_2111_;
																							loc_2111_ = loc_2147_;
																							loc_2147_ = loc_2117_;
																							if rt_greater_than_s32(loc_2138_, rt_exclusive_or_i32(loc_2148_, 2147483647)) then
																								loc_2119_ = loc_2146_;
																								loc_2146_ = loc_2135_;
																								loc_2135_ = loc_2151_;
																								loc_2150_ = loc_2136_;
																								loc_2151_ = loc_2149_;
																								loc_2149_ = 1;
																								loc_2136_ = 0;
																								loc_2117_ = 17;
																							else
																								loc_2119_ = loc_2146_;
																								loc_2146_ = loc_2135_;
																								loc_2150_ = loc_2136_;
																								loc_2149_, loc_2151_ = loc_2151_, loc_2149_;
																								loc_2149_ = 0;
																								if rt_greater_than_s32(loc_2138_, 0) then
																									loc_2117_ = loc_2150_;
																									loc_2135_ = loc_2138_;
																									loc_2136_ = loc_2151_;
																									loc_2151_ = loc_2149_;
																								else
																									loc_2117_ = loc_2150_;
																									loc_2136_ = loc_2151_;
																									loc_2150_ = loc_2138_;
																									loc_2151_ = loc_2149_;
																									loc_2135_ = loc_2151_;
																								end
																								loc_2149_ = 0;
																							end
																						end
																						if (loc_2149_) >= 0 and (loc_2149_) < 2 then
																							if (loc_2149_) < 1 then
																								loc_2135_ = bit32_or(loc_2135_ + loc_2148_, 0);
																								if rt_greater_than_s32(loc_2135_, rt_exclusive_or_i32(loc_2147_, 2147483647)) then
																									loc_2136_ = loc_2111_;
																									loc_2148_ = loc_2117_;
																									loc_2143_ = 4;
																									loc_2136_ = 0;
																									loc_2117_ = 19;
																								else
																									loc_2136_ = loc_2111_;
																									loc_2148_ = loc_2117_;
																									loc_2131_ = bit32_or(loc_2135_ + loc_2147_, 0);
																									loc_2141_ = rt_and_i32(loc_2141_, 73728);
																									if rt_not_equal_i32(loc_2141_, 0) then
																										loc_2117_ = loc_2145_;
																										loc_2145_ = loc_2148_;
																										loc_2148_ = loc_2131_;
																										loc_2131_ = loc_2143_;
																										loc_2143_ = loc_2135_;
																										loc_2135_ = loc_2130_;
																										loc_2130_ = loc_2147_;
																										loc_2147_ = loc_2146_;
																										loc_2146_ = loc_2099_;
																										loc_2136_, loc_2144_ = loc_2144_, loc_2136_;
																									else
																										loc_2117_ = loc_2145_;
																										loc_2145_ = loc_2148_;
																										loc_2148_ = loc_2131_;
																										loc_2131_ = loc_2143_;
																										loc_2143_ = loc_2135_;
																										loc_2135_ = loc_2130_;
																										loc_2130_ = loc_2147_;
																										loc_2147_ = loc_2146_;
																										loc_2146_ = loc_2099_;
																										loc_2136_, loc_2144_ = loc_2144_, loc_2136_;
																										if not (rt_less_than_equal_s32(loc_2135_, loc_2148_)) then
																											loc_2111_ = bit32_or(loc_2135_ - loc_2148_, 0);
																											loc_2140_ = (rt_less_than_u32(loc_2111_, 256) and 1 or 0);
																											loc_2099_ = 256;
																											if rt_not_equal_i32(loc_2140_, 0) then
																												loc_2143_ = loc_2111_;
																											else
																												loc_2143_ = loc_2111_;
																												loc_2111_ = loc_2099_;
																											end
																											if not (rt_equal_i32(loc_2111_, 0)) then
																												rt_memory_fill(loc_2102_, bit32_or(loc_2103_ + 608, 0), 32, loc_2111_)
																											end
																											if not (rt_not_equal_i32(loc_2140_, 0)) then
																												repeat
																													rt_yield_budget = rt_yield_budget - 1
																													if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																													loc_2111_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																													if not (rt_not_equal_i32(rt_and_i32(loc_2111_, 32), 0)) then
																														loc_2111_ = loc_2104_;
																														loc_2104_ = loc_2111_;
																														loc_2111_ = loc_2111_[1](bit32_or(loc_2103_ + 608, 0), 256, loc_2112_, loc_2146_)
																													end
																													loc_2111_ = bit32_or(loc_2143_ + -256, 0);
																													loc_2143_ = loc_2111_;
																												until not (rt_greater_than_u32(loc_2111_, 255))
																											end
																											loc_2111_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																											if not (rt_not_equal_i32(rt_and_i32(loc_2111_, 32), 0)) then
																												loc_2111_ = loc_2104_;
																												loc_2104_ = loc_2111_;
																												loc_2111_ = loc_2111_[1](bit32_or(loc_2103_ + 608, 0), loc_2143_, loc_2112_, loc_2146_)
																											end
																										end
																									end
																									loc_2111_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																									if not (rt_not_equal_i32(rt_and_i32(loc_2111_, 32), 0)) then
																										loc_2111_ = loc_2104_;
																										loc_2104_ = loc_2111_;
																										loc_2130_ = loc_2111_[1](loc_2117_, loc_2130_, loc_2112_, loc_2146_)
																									end
																									if not (rt_not_equal_i32(loc_2141_, 65536)) then
																										if not (rt_less_than_equal_s32(loc_2135_, loc_2148_)) then
																											loc_2130_ = bit32_or(loc_2135_ - loc_2148_, 0);
																											loc_2140_ = (rt_less_than_u32(loc_2130_, 256) and 1 or 0);
																											loc_2117_ = 256;
																											if rt_not_equal_i32(loc_2140_, 0) then
																												loc_2143_ = loc_2130_;
																											else
																												loc_2143_ = loc_2130_;
																												loc_2130_ = loc_2117_;
																											end
																											if not (rt_equal_i32(loc_2130_, 0)) then
																												rt_memory_fill(loc_2102_, bit32_or(loc_2103_ + 608, 0), 48, loc_2130_)
																											end
																											if not (rt_not_equal_i32(loc_2140_, 0)) then
																												repeat
																													rt_yield_budget = rt_yield_budget - 1
																													if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																													loc_2130_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																													if not (rt_not_equal_i32(rt_and_i32(loc_2130_, 32), 0)) then
																														loc_2130_ = loc_2104_;
																														loc_2104_ = loc_2130_;
																														loc_2130_ = loc_2130_[1](bit32_or(loc_2103_ + 608, 0), 256, loc_2112_, loc_2146_)
																													end
																													loc_2130_ = bit32_or(loc_2143_ + -256, 0);
																													loc_2143_ = loc_2130_;
																												until not (rt_greater_than_u32(loc_2130_, 255))
																											end
																											loc_2130_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																											if not (rt_not_equal_i32(rt_and_i32(loc_2130_, 32), 0)) then
																												loc_2130_ = loc_2104_;
																												loc_2104_ = loc_2130_;
																												loc_2130_ = loc_2130_[1](bit32_or(loc_2103_ + 608, 0), loc_2143_, loc_2112_, loc_2146_)
																											end
																										end
																									end
																									if rt_not_equal_i32(loc_2131_, 0) then
																										if not (rt_less_than_s32(loc_2129_, 0)) then
																											loc_2143_ = loc_2142_;
																											loc_2143_ = bit32_or(loc_2139_ + 4, 0);
																											if rt_greater_than_u32(loc_2137_, loc_2139_) then
																												loc_2142_ = loc_2139_;
																											else
																												loc_2142_ = loc_2139_;
																												loc_2139_ = loc_2137_;
																												loc_2137_ = loc_2143_;
																											end
																											loc_2139_ = loc_2142_;
																											repeat
																												rt_yield_budget = rt_yield_budget - 1
																												if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																												loc_2143_ = loc_2140_;
																												loc_2140_ = buffer_read_i32(loc_2102_[1], loc_2142_, 0);
																												if rt_equal_i32(loc_2140_, 0) then
																													loc_2143_ = loc_2129_;
																													loc_2145_ = loc_2142_;
																													loc_2142_ = loc_2125_;
																													rt_store_i32_into_i8(loc_2102_, loc_2103_, 72, 48)
																													loc_2125_ = loc_2142_;
																												else
																													loc_2136_ = loc_2125_;
																													loc_2143_ = loc_2129_;
																													loc_2145_ = loc_2142_;
																													loc_2142_ = loc_2126_;
																													loc_2125_ = loc_2136_;
																													loc_2126_ = loc_2142_;
																													repeat
																														rt_yield_budget = rt_yield_budget - 1
																														if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																														loc_2138_, loc_2140_ = loc_2140_, loc_2138_;
																														loc_2142_ = bit32_or(loc_2142_ + -1, 0);
																														loc_2131_ = rt_divide_u32(loc_2138_, 10);
																														rt_store_i32_into_i8(loc_2102_, loc_2142_, 0, rt_or_i32(bit32_or(loc_2138_ - rt_multiply_i32(loc_2131_, 10), 0), 48))
																														loc_2140_ = loc_2131_;
																														loc_2136_ = (rt_less_than_u32(loc_2138_, 10) and 1 or 0);
																														loc_2138_ = loc_2136_;
																													until not (rt_equal_i32(loc_2136_, 0))
																												end
																												if rt_equal_i32(loc_2145_, loc_2139_) then
																													loc_2140_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																													if not (rt_not_equal_i32(rt_and_i32(loc_2140_, 32), 0)) then
																														loc_2140_ = loc_2104_;
																														loc_2104_ = loc_2140_;
																														loc_2140_ = loc_2140_[1](loc_2142_, 1, loc_2112_, loc_2146_)
																													end
																													loc_2140_ = bit32_or(loc_2142_ + 1, 0);
																													if not (rt_equal_i32(rt_or_i32(loc_2143_, loc_2144_), 0)) then
																														loc_2142_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																														if not (rt_not_equal_i32(rt_and_i32(loc_2142_, 32), 0)) then
																															loc_2142_ = loc_2104_;
																															loc_2104_ = loc_2142_;
																															loc_2142_ = loc_2142_[1](1631, 1, loc_2112_, loc_2146_)
																														end
																													end
																												else
																													if rt_less_than_equal_u32(loc_2142_, bit32_or(loc_2103_ + 64, 0)) then
																														loc_2140_ = loc_2142_;
																													else
																														loc_2140_ = loc_2142_;
																														loc_2140_ = bit32_or(loc_2140_ - bit32_or(loc_2103_ + 64, 0), 0);
																														if rt_equal_i32(loc_2140_, 0) then
																															loc_2142_ = loc_2103_;
																														else
																															loc_2142_ = loc_2103_;
																															rt_memory_fill(loc_2102_, bit32_or(loc_2142_ + 64, 0), 48, loc_2140_)
																														end
																														loc_2103_ = loc_2142_;
																														loc_2140_ = bit32_or(loc_2142_ + 64, 0);
																													end
																												end
																												loc_2136_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																												loc_2142_ = bit32_or(loc_2126_ - loc_2140_, 0);
																												if not (rt_not_equal_i32(rt_and_i32(loc_2136_, 32), 0)) then
																													if rt_less_than_s32(loc_2142_, loc_2143_) then
																														loc_2129_ = loc_2143_;
																														loc_2130_ = loc_2104_;
																														loc_2131_ = loc_2140_;
																														loc_2136_ = loc_2142_;
																													else
																														loc_2129_ = loc_2143_;
																														loc_2130_ = loc_2104_;
																														loc_2131_ = loc_2140_;
																														loc_2136_ = loc_2142_;
																														loc_2136_ = loc_2129_;
																													end
																													loc_2104_ = loc_2130_;
																													loc_2136_ = loc_2130_[1](loc_2131_, loc_2136_, loc_2112_, loc_2146_)
																												end
																												loc_2129_ = bit32_or(loc_2143_ - loc_2142_, 0);
																												loc_2142_ = bit32_or(loc_2145_ + 4, 0);
																												if rt_greater_than_equal_u32(loc_2142_, loc_2137_) then
																													loc_2143_ = 0;
																													loc_2145_ = 1;
																												else
																													if rt_greater_than_s32(loc_2129_, -1) then
																														loc_2143_ = 1;
																														loc_2145_ = 65535;
																													else
																														loc_2143_ = 0;
																														loc_2145_ = 0;
																													end
																												end
																											until loc_2143_ == 0
																											if rt_not_equal_i32(loc_2145_, 0) then
																											end
																										end
																										loc_2110_[1](loc_2112_, 48, bit32_or(loc_2129_ + 18, 0), 18, 0, loc_2146_)
																										loc_2146_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																										if not (rt_not_equal_i32(rt_and_i32(loc_2146_, 32), 0)) then
																											loc_2145_ = loc_2104_;
																											loc_2104_ = loc_2145_;
																											loc_2146_ = loc_2099_;
																											loc_2147_ = loc_2145_[1](loc_2147_, bit32_or(loc_2119_ - loc_2147_, 0), loc_2112_, loc_2146_)
																										end
																									else
																										loc_2138_, loc_2144_ = loc_2144_, loc_2138_;
																										loc_2142_, loc_2147_ = loc_2147_, loc_2142_;
																										if rt_greater_than_u32(loc_2139_, loc_2132_) then
																											loc_2138_ = loc_2132_;
																											loc_2142_ = loc_2139_;
																											loc_2144_ = loc_2145_;
																											loc_2145_ = loc_2110_;
																											loc_2147_ = loc_2146_;
																											loc_2146_ = loc_2143_;
																											loc_2143_ = loc_2136_;
																										else
																											loc_2138_ = loc_2132_;
																											loc_2142_ = loc_2139_;
																											loc_2144_ = loc_2145_;
																											loc_2145_ = loc_2110_;
																											loc_2147_ = loc_2146_;
																											loc_2146_ = loc_2143_;
																											loc_2143_ = loc_2136_;
																											loc_2138_ = loc_2142_;
																										end
																										loc_2142_ = loc_2138_;
																										repeat
																											rt_yield_budget = rt_yield_budget - 1
																											if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																											loc_2146_ = buffer_read_i32(loc_2102_[1], loc_2142_, 0);
																											if rt_equal_i32(loc_2146_, 0) then
																												loc_2131_ = loc_2132_;
																												loc_2139_ = 9;
																												if rt_not_equal_i32(loc_2142_, loc_2138_) then
																													loc_2136_ = 1;
																												else
																													loc_2136_ = 0;
																												end
																											else
																												loc_2131_ = loc_2132_;
																												loc_2140_ = 8;
																												repeat
																													rt_yield_budget = rt_yield_budget - 1
																													if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																													loc_2139_ = loc_2146_;
																													loc_2136_ = rt_divide_u32(loc_2139_, 10);
																													rt_store_i32_into_i8(loc_2102_, bit32_or(bit32_or(loc_2103_ + 64, 0) + loc_2140_, 0), 0, rt_or_i32(bit32_or(loc_2139_ - rt_multiply_i32(loc_2136_, 10), 0), 48))
																													loc_2146_ = loc_2136_;
																													loc_2140_ = bit32_or(loc_2140_ + -1, 0);
																												until not (rt_greater_than_u32(loc_2139_, 9))
																												loc_2139_ = bit32_or(loc_2140_ + 1, 0);
																												loc_2146_ = bit32_or(loc_2139_ + bit32_or(loc_2103_ + 64, 0), 0);
																												if rt_equal_i32(loc_2142_, loc_2138_) then
																													if rt_not_equal_i32(loc_2140_, 8) then
																														loc_2136_ = 2;
																													else
																														loc_2136_ = 0;
																													end
																												else
																													if rt_less_than_s32(bit32_or(loc_2140_ + 2, 0), 2) then
																														loc_2136_ = 2;
																													else
																														loc_2136_ = 1;
																													end
																												end
																											end
																											if (loc_2136_) >= 0 and (loc_2136_) < 2 then
																												if (loc_2136_) < 1 then
																													loc_2136_ = loc_2146_;
																													loc_2146_ = loc_2125_;
																													rt_store_i32_into_i8(loc_2102_, loc_2103_, 72, 48)
																													loc_2125_ = loc_2146_;
																												else
																													loc_2140_ = bit32_or(loc_2139_ + bit32_or(loc_2103_ + 64, 0), 0);
																													loc_2146_ = bit32_or(loc_2103_ + 64, 0);
																													loc_2136_ = bit32_or(loc_2124_ + loc_2139_, 0);
																													if not (rt_less_than_u32(bit32_or(loc_2103_ + 64, 0), loc_2136_)) then
																														loc_2146_ = loc_2136_;
																													end
																													loc_2140_ = bit32_or(loc_2140_ - loc_2146_, 0);
																													if not (rt_equal_i32(loc_2140_, 0)) then
																														rt_memory_fill(loc_2102_, loc_2146_, 48, loc_2140_)
																													end
																												end
																											else
																											end
																											loc_2136_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																											if not (rt_not_equal_i32(rt_and_i32(loc_2136_, 32), 0)) then
																												loc_2136_ = loc_2104_;
																												loc_2104_ = loc_2136_;
																												loc_2136_ = loc_2136_[1](loc_2146_, bit32_or(loc_2126_ - loc_2146_, 0), loc_2112_, loc_2147_)
																											end
																											loc_2136_ = bit32_or(loc_2142_ + 4, 0);
																											loc_2142_ = loc_2136_;
																											loc_2132_ = loc_2131_;
																										until not (rt_less_than_equal_u32(loc_2136_, loc_2131_))
																										if not (rt_equal_i32(loc_2143_, 0)) then
																											loc_2143_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																											if not (rt_not_equal_i32(rt_and_i32(loc_2143_, 32), 0)) then
																												loc_2143_ = loc_2104_;
																												loc_2104_ = loc_2143_;
																												loc_2143_ = loc_2143_[1](1631, 1, loc_2112_, loc_2147_)
																											end
																										end
																										if rt_greater_than_equal_s32(loc_2129_, 1) then
																											if rt_less_than_u32(loc_2142_, loc_2137_) then
																												repeat
																													rt_yield_budget = rt_yield_budget - 1
																													if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																													loc_2143_ = loc_2140_;
																													loc_2140_ = loc_2139_;
																													loc_2144_, loc_2146_ = loc_2146_, loc_2144_;
																													loc_2146_ = buffer_read_i32(loc_2102_[1], loc_2142_, 0);
																													if rt_not_equal_i32(loc_2146_, 0) then
																														loc_2139_ = loc_2126_;
																														loc_2144_ = loc_2142_;
																														loc_2126_ = loc_2139_;
																														loc_2140_ = loc_2139_;
																														repeat
																															rt_yield_budget = rt_yield_budget - 1
																															if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																															loc_2143_ = loc_2146_;
																															loc_2146_ = loc_2138_;
																															loc_2140_ = bit32_or(loc_2140_ + -1, 0);
																															loc_2142_ = rt_divide_u32(loc_2143_, 10);
																															rt_store_i32_into_i8(loc_2102_, loc_2140_, 0, rt_or_i32(bit32_or(loc_2143_ - rt_multiply_i32(loc_2142_, 10), 0), 48))
																															loc_2146_ = loc_2142_;
																															loc_2139_ = bit32_or(loc_2139_ + -1, 0);
																															loc_2143_ = (rt_greater_than_u32(loc_2143_, 9) and 1 or 0);
																															loc_2138_ = loc_2143_;
																														until loc_2143_ == 0
																														if rt_less_than_equal_u32(loc_2140_, bit32_or(loc_2103_ + 64, 0)) then
																															loc_2146_ = 1;
																														else
																															loc_2146_ = 0;
																														end
																													else
																														loc_2139_ = loc_2126_;
																														loc_2144_ = loc_2142_;
																														loc_2146_ = 0;
																														loc_2126_ = loc_2139_;
																														loc_2140_ = loc_2139_;
																													end
																													if not (rt_not_equal_i32(loc_2146_, 0)) then
																														loc_2146_ = bit32_or(loc_2139_ - bit32_or(loc_2103_ + 64, 0), 0);
																														loc_2140_ = bit32_or(bit32_or(loc_2140_ + bit32_or(loc_2103_ + 64, 0), 0) - loc_2139_, 0);
																														if not (rt_equal_i32(loc_2146_, 0)) then
																															rt_memory_fill(loc_2102_, loc_2140_, 48, loc_2146_)
																														end
																													end
																													loc_2146_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																													if not (rt_not_equal_i32(rt_and_i32(loc_2146_, 32), 0)) then
																														loc_2136_ = 9;
																														if rt_less_than_u32(loc_2129_, 9) then
																															loc_2142_ = loc_2104_;
																															loc_2143_ = loc_2140_;
																															loc_2146_ = loc_2129_;
																														else
																															loc_2142_ = loc_2104_;
																															loc_2143_ = loc_2140_;
																															loc_2146_ = loc_2129_;
																															loc_2146_ = loc_2136_;
																														end
																														loc_2104_ = loc_2142_;
																														loc_2146_ = loc_2142_[1](loc_2143_, loc_2146_, loc_2112_, loc_2147_)
																													end
																													loc_2146_ = bit32_or(loc_2129_ + -9, 0);
																													loc_2142_ = bit32_or(loc_2144_ + 4, 0);
																													if rt_greater_than_equal_u32(loc_2142_, loc_2137_) then
																														loc_2143_ = 0;
																														loc_2144_ = 1;
																													else
																														loc_2144_ = loc_2140_;
																														loc_2140_ = (rt_greater_than_s32(loc_2129_, 9) and 1 or 0);
																														if rt_not_equal_i32(loc_2140_, 0) then
																															loc_2129_ = loc_2146_;
																															loc_2143_ = 1;
																															loc_2144_ = 65535;
																														else
																															loc_2129_ = loc_2146_;
																															loc_2143_ = 0;
																															loc_2144_ = 0;
																														end
																													end
																												until loc_2143_ == 0
																												if rt_not_equal_i32(loc_2144_, 0) then
																												end
																											else
																												loc_2144_, loc_2146_ = loc_2146_, loc_2144_;
																												loc_2146_ = loc_2129_;
																											end
																										else
																											loc_2144_, loc_2146_ = loc_2146_, loc_2144_;
																											loc_2146_ = loc_2129_;
																										end
																										loc_2110_ = loc_2145_;
																										loc_2145_[1](loc_2112_, 48, bit32_or(loc_2146_ + 9, 0), 9, 0, loc_2147_)
																									end
																									if not (rt_not_equal_i32(loc_2141_, 8192)) then
																										if not (rt_less_than_equal_s32(loc_2135_, loc_2148_)) then
																											loc_2146_ = loc_2139_;
																											loc_2147_ = loc_2140_;
																											loc_2139_ = bit32_or(loc_2135_ - loc_2148_, 0);
																											loc_2140_ = (rt_less_than_u32(loc_2139_, 256) and 1 or 0);
																											loc_2146_ = 256;
																											if rt_not_equal_i32(loc_2140_, 0) then
																												loc_2147_ = loc_2139_;
																											else
																												loc_2145_ = loc_2139_;
																												loc_2147_ = loc_2139_;
																												loc_2139_ = loc_2146_;
																											end
																											if not (rt_equal_i32(loc_2139_, 0)) then
																												rt_memory_fill(loc_2102_, bit32_or(loc_2103_ + 608, 0), 32, loc_2139_)
																											end
																											if not (rt_not_equal_i32(loc_2140_, 0)) then
																												repeat
																													rt_yield_budget = rt_yield_budget - 1
																													if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																													loc_2146_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																													if not (rt_not_equal_i32(rt_and_i32(loc_2146_, 32), 0)) then
																														loc_2145_ = loc_2104_;
																														loc_2104_ = loc_2145_;
																														loc_2146_ = loc_2099_;
																														loc_2146_ = loc_2145_[1](bit32_or(loc_2103_ + 608, 0), 256, loc_2112_, loc_2146_)
																													end
																													loc_2146_ = bit32_or(loc_2147_ + -256, 0);
																													loc_2147_ = loc_2146_;
																												until not (rt_greater_than_u32(loc_2146_, 255))
																											end
																											loc_2146_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																											if not (rt_not_equal_i32(rt_and_i32(loc_2146_, 32), 0)) then
																												loc_2145_ = loc_2104_;
																												loc_2104_ = loc_2145_;
																												loc_2146_ = loc_2099_;
																												loc_2147_ = loc_2145_[1](bit32_or(loc_2103_ + 608, 0), loc_2147_, loc_2112_, loc_2146_)
																											end
																										end
																									end
																									if rt_greater_than_s32(loc_2135_, loc_2148_) then
																										loc_2130_ = loc_2135_;
																										loc_2131_ = loc_2148_;
																									else
																										loc_2130_ = loc_2135_;
																										loc_2131_ = loc_2148_;
																										loc_2147_ = loc_2135_;
																										loc_2135_ = loc_2148_;
																									end
																									loc_2143_ = 4;
																									loc_2136_ = 1;
																									loc_2117_ = 65535;
																								end
																							else
																								loc_2111_, loc_2148_ = loc_2148_, loc_2111_;
																								loc_2148_, loc_2147_ = loc_2147_, loc_2148_;
																								loc_2147_, loc_2146_ = loc_2146_, loc_2147_;
																								loc_2146_, loc_2145_ = loc_2145_, loc_2146_;
																								loc_2145_, loc_2144_ = loc_2144_, loc_2145_;
																								loc_2144_, loc_2143_ = loc_2143_, loc_2144_;
																								loc_2143_ = 4;
																							end
																						else
																							loc_2143_ = 4;
																						end
																					end
																				end
																			else
																				loc_2143_ = loc_2131_;
																				loc_2145_ = loc_2132_;
																				loc_2146_ = loc_2135_;
																				loc_2147_ = loc_2153_;
																				loc_2153_ = loc_2136_;
																				loc_2136_ = loc_2117_;
																				loc_2153_ = bit32_or(loc_2137_ + 3, 0);
																				if rt_not_equal_i32(rt_and_i32(loc_2141_, 8192), 0) then
																					loc_2099_ = loc_2147_;
																					loc_2103_ = loc_2144_;
																					loc_2131_ = loc_2149_;
																					loc_2132_ = loc_2148_;
																					loc_2135_ = loc_2130_;
																					loc_2149_ = loc_2138_;
																					loc_2138_ = loc_2150_;
																					loc_2150_ = loc_2137_;
																					loc_2137_ = loc_2123_;
																					loc_2123_ = loc_2140_;
																					loc_2139_, loc_2151_ = loc_2151_, loc_2139_;
																					loc_2151_, loc_2152_ = loc_2152_, loc_2151_;
																				else
																					loc_2099_ = loc_2147_;
																					loc_2103_ = loc_2144_;
																					loc_2131_ = loc_2149_;
																					loc_2132_ = loc_2148_;
																					loc_2135_ = loc_2130_;
																					loc_2149_ = loc_2138_;
																					loc_2138_ = loc_2150_;
																					loc_2150_ = loc_2137_;
																					loc_2137_ = loc_2123_;
																					loc_2123_ = loc_2140_;
																					loc_2139_, loc_2151_ = loc_2151_, loc_2139_;
																					loc_2151_, loc_2152_ = loc_2152_, loc_2151_;
																					if not (rt_less_than_equal_u32(loc_2135_, loc_2153_)) then
																						loc_2148_ = loc_2139_;
																						loc_2147_ = bit32_or(loc_2135_ - loc_2153_, 0);
																						loc_2139_ = (rt_less_than_u32(loc_2147_, 256) and 1 or 0);
																						loc_2146_ = 256;
																						if rt_not_equal_i32(loc_2139_, 0) then
																							loc_2148_ = loc_2147_;
																						else
																							loc_2148_ = loc_2147_;
																							loc_2147_ = loc_2146_;
																						end
																						if not (rt_equal_i32(loc_2147_, 0)) then
																							rt_memory_fill(loc_2102_, bit32_or(loc_2103_ + 608, 0), 32, loc_2147_)
																						end
																						if not (rt_not_equal_i32(loc_2139_, 0)) then
																							loc_2147_ = loc_2129_;
																							repeat
																								rt_yield_budget = rt_yield_budget - 1
																								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																								loc_2147_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																								if not (rt_not_equal_i32(rt_and_i32(loc_2147_, 32), 0)) then
																									loc_2146_ = loc_2104_;
																									loc_2104_ = loc_2146_;
																									loc_2147_ = loc_2099_;
																									loc_2147_ = loc_2146_[1](bit32_or(loc_2103_ + 608, 0), 256, loc_2112_, loc_2147_)
																								end
																								loc_2147_ = bit32_or(loc_2148_ + -256, 0);
																								loc_2148_ = loc_2147_;
																							until not (rt_greater_than_u32(loc_2147_, 255))
																							loc_2129_ = buffer_read_i32(loc_2102_[1], loc_2112_, 0);
																						end
																						if not (rt_not_equal_i32(rt_and_i32(loc_2129_, 32), 0)) then
																							loc_2146_ = loc_2104_;
																							loc_2147_ = loc_2129_;
																							loc_2104_ = loc_2146_;
																							loc_2147_ = loc_2099_;
																							loc_2148_ = loc_2146_[1](bit32_or(loc_2103_ + 608, 0), loc_2148_, loc_2112_, loc_2147_)
																							loc_2129_ = buffer_read_i32(loc_2102_[1], loc_2112_, 0);
																						end
																					end
																				end
																				if not (rt_not_equal_i32(rt_and_i32(loc_2129_, 32), 0)) then
																					loc_2147_ = loc_2104_;
																					loc_2148_ = loc_2129_;
																					loc_2104_ = loc_2147_;
																					loc_2148_ = loc_2099_;
																					loc_2150_ = loc_2147_[1](loc_2149_, loc_2150_, loc_2112_, loc_2148_)
																					loc_2129_ = buffer_read_i32(loc_2102_[1], loc_2112_, 0);
																				end
																				if not (rt_not_equal_i32(rt_and_i32(loc_2129_, 32), 0)) then
																					loc_2146_ = rt_and_i32(loc_2152_, 32);
																					loc_2152_ = 1181;
																					loc_2149_ = 1233;
																					if rt_not_equal_i32(loc_2146_, 0) then
																						loc_2148_ = loc_2151_;
																						loc_2150_ = loc_2104_;
																						loc_2151_ = loc_2152_;
																						loc_2152_ = loc_2099_;
																					else
																						loc_2148_ = loc_2151_;
																						loc_2150_ = loc_2104_;
																						loc_2151_ = loc_2152_;
																						loc_2152_ = loc_2099_;
																						loc_2151_ = loc_2149_;
																					end
																					loc_2149_ = 1202;
																					loc_2147_ = 1237;
																					if not (rt_not_equal_i32(loc_2146_, 0)) then
																						loc_2149_ = loc_2147_;
																					end
																					if not (rt_not_equal_f64(loc_2148_, loc_2148_)) then
																						loc_2151_ = loc_2149_;
																					end
																					loc_2104_ = loc_2150_;
																					loc_2152_ = loc_2150_[1](loc_2151_, 3, loc_2112_, loc_2152_)
																				end
																				if not (rt_not_equal_i32(rt_and_i32(loc_2141_, 73728), 8192)) then
																					if not (rt_less_than_equal_u32(loc_2135_, loc_2153_)) then
																						loc_2152_ = loc_2139_;
																						loc_2151_ = bit32_or(loc_2135_ - loc_2153_, 0);
																						loc_2139_ = (rt_less_than_u32(loc_2151_, 256) and 1 or 0);
																						loc_2150_ = 256;
																						if rt_not_equal_i32(loc_2139_, 0) then
																							loc_2152_ = loc_2151_;
																						else
																							loc_2152_ = loc_2151_;
																							loc_2151_ = loc_2150_;
																						end
																						if not (rt_equal_i32(loc_2151_, 0)) then
																							rt_memory_fill(loc_2102_, bit32_or(loc_2103_ + 608, 0), 32, loc_2151_)
																						end
																						if not (rt_not_equal_i32(loc_2139_, 0)) then
																							repeat
																								rt_yield_budget = rt_yield_budget - 1
																								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																								loc_2151_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																								if not (rt_not_equal_i32(rt_and_i32(loc_2151_, 32), 0)) then
																									loc_2150_ = loc_2104_;
																									loc_2104_ = loc_2150_;
																									loc_2151_ = loc_2099_;
																									loc_2151_ = loc_2150_[1](bit32_or(loc_2103_ + 608, 0), 256, loc_2112_, loc_2151_)
																								end
																								loc_2151_ = bit32_or(loc_2152_ + -256, 0);
																								loc_2152_ = loc_2151_;
																							until not (rt_greater_than_u32(loc_2151_, 255))
																						end
																						loc_2151_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																						if not (rt_not_equal_i32(rt_and_i32(loc_2151_, 32), 0)) then
																							loc_2150_ = loc_2104_;
																							loc_2104_ = loc_2150_;
																							loc_2151_ = loc_2099_;
																							loc_2152_ = loc_2150_[1](bit32_or(loc_2103_ + 608, 0), loc_2152_, loc_2112_, loc_2151_)
																						end
																					end
																				end
																				if rt_greater_than_u32(loc_2135_, loc_2153_) then
																					loc_2130_ = loc_2135_;
																					loc_2140_ = loc_2153_;
																				else
																					loc_2130_ = loc_2135_;
																					loc_2140_ = loc_2153_;
																					loc_2152_ = loc_2135_;
																					loc_2135_ = loc_2153_;
																				end
																				loc_2143_ = 4;
																				loc_2136_ = 1;
																				loc_2117_ = 65535;
																			end
																		end
																	else
																		loc_2144_ = loc_2143_;
																		loc_2143_ = loc_2129_;
																		loc_2129_ = loc_2133_;
																		loc_2133_ = loc_2111_;
																		loc_2133_ = rt_load_i64(loc_2102_, loc_2103_, 40);
																		if rt_greater_than_s64(loc_2133_, into_bits_i64(4294967295, 4294967295)) then
																			if rt_equal_i32(rt_and_i32(loc_2141_, 2048), 0) then
																				loc_2129_ = rt_and_i32(loc_2141_, 1);
																				loc_2132_ = 1034;
																				loc_2144_ = 1032;
																				if not (rt_not_equal_i32(loc_2129_, 0)) then
																					loc_2143_ = loc_2132_;
																					loc_2132_ = loc_2144_;
																				end
																				loc_2143_ = 1;
																			else
																				loc_2143_ = 1;
																				loc_2129_ = 1;
																				loc_2132_ = 1033;
																			end
																		else
																			loc_2133_ = rt_subtract_i64(into_bits_i64(0, 0), loc_2133_);
																			rt_store_i64(loc_2102_, loc_2103_, 40, loc_2133_)
																			loc_2143_ = 1;
																			loc_2129_ = 1;
																			loc_2132_ = 1032;
																		end
																	end
																else
																	loc_2146_ = loc_2132_;
																	loc_2147_ = loc_2111_;
																	loc_2148_ = loc_2138_;
																	loc_2149_ = loc_2129_;
																	loc_2150_ = loc_2143_;
																	loc_2151_ = loc_2140_;
																	loc_2152_ = loc_2128_;
																	loc_2153_ = loc_2122_;
																	rt_store_i32_into_i8(loc_2102_, loc_2103_, 39, loc_2135_)
																	loc_2143_ = 3;
																	loc_2122_ = loc_2153_;
																	loc_2128_ = loc_2152_;
																	loc_2135_ = loc_2152_;
																	loc_2140_ = loc_2153_;
																	loc_2129_ = 0;
																	loc_2138_ = 1;
																	loc_2132_ = 1032;
																end
															elseif (loc_2153_) > 5 then
																if (loc_2153_) < 8 then
																	if (loc_2153_) < 7 then
																		loc_2144_ = loc_2143_;
																		loc_2143_ = loc_2111_;
																		loc_2143_ = 1;
																	else
																		loc_2144_ = loc_2140_;
																		loc_2140_ = loc_2129_;
																		loc_2132_, loc_2133_ = loc_2133_, loc_2132_;
																		loc_2133_ = rt_load_i64(loc_2102_, loc_2103_, 40);
																		loc_2129_ = 0;
																		loc_2132_ = 1032;
																		if rt_equal_i32((rt_equal_i64_constant(loc_2133_, 0, 0) and 1 or 0), 0) then
																			loc_2140_ = loc_2128_;
																			loc_2143_ = loc_2111_;
																			loc_2128_ = loc_2140_;
																			loc_2111_ = rt_and_i32(loc_2143_, 32);
																			repeat
																				rt_yield_budget = rt_yield_budget - 1
																				if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																				loc_2144_ = loc_2135_;
																				loc_2144_ = rt_load_i32_from_u8(loc_2102_, rt_and_i32(rt_narrow_i64(loc_2133_), 15), 10656);
																				loc_2140_ = bit32_or(loc_2140_ + -1, 0);
																				rt_store_i32_into_i8(loc_2102_, loc_2140_, 0, rt_or_i32(loc_2144_, loc_2111_))
																				loc_2144_ = (rt_greater_than_u64(loc_2133_, into_bits_i64(15, 0)) and 1 or 0);
																				loc_2135_ = loc_2144_;
																				loc_2133_ = rt_shift_right_u64(loc_2133_, 4);
																			until loc_2144_ == 0
																			if rt_equal_i32(rt_and_i32(loc_2141_, 8), 0) then
																				loc_2143_ = 2;
																			else
																				loc_2129_, loc_2132_ = loc_2132_, loc_2129_;
																				loc_2132_, loc_2143_ = loc_2143_, loc_2132_;
																				loc_2143_ = 2;
																				loc_2129_ = 2;
																				loc_2132_ = bit32_or(rt_shift_right_u32(loc_2132_, 4) + 1032, 0);
																			end
																		else
																			loc_2140_ = loc_2128_;
																			loc_2144_ = loc_2111_;
																			loc_2143_ = 2;
																			loc_2128_ = loc_2140_;
																		end
																	end
																elseif (loc_2153_) > 8 then
																	loc_2111_, loc_2132_ = loc_2132_, loc_2111_;
																	loc_2132_, loc_2138_ = loc_2138_, loc_2132_;
																	loc_2138_, loc_2142_ = loc_2142_, loc_2138_;
																	loc_2142_, loc_2128_ = loc_2128_, loc_2142_;
																	loc_2129_, loc_2137_ = loc_2137_, loc_2129_;
																	loc_2137_, loc_2143_ = loc_2143_, loc_2137_;
																	loc_2143_, loc_2135_ = loc_2135_, loc_2143_;
																	loc_2143_ = 3;
																	loc_2128_ = loc_2142_;
																	loc_2135_ = loc_2142_;
																	loc_2129_ = 0;
																	loc_2142_ = loc_2138_;
																	loc_2137_ = loc_2141_;
																	loc_2132_ = 1032;
																else
																	loc_2143_ = 2;
																end
															else
																loc_2144_ = loc_2135_;
																loc_2135_ = loc_2138_;
																loc_2138_ = loc_2129_;
																loc_2129_ = loc_2132_;
																loc_2132_ = loc_2111_;
																loc_2132_ = 2147483647;
																if rt_less_than_u32(loc_2142_, 2147483647) then
																	loc_2135_ = loc_2140_;
																	loc_2138_ = loc_2142_;
																	loc_2143_ = loc_2099_;
																	loc_2144_ = loc_2140_;
																else
																	loc_2135_ = loc_2140_;
																	loc_2138_ = loc_2142_;
																	loc_2143_ = loc_2099_;
																	loc_2144_ = loc_2140_;
																	loc_2138_ = loc_2132_;
																end
																loc_2138_ = loc_2106_[1](loc_2135_, loc_2138_, loc_2143_)
																loc_2135_ = bit32_or(loc_2144_ + loc_2138_, 0);
																loc_2129_ = 0;
																loc_2132_ = 1032;
																if rt_greater_than_s32(loc_2142_, -1) then
																	loc_2143_ = 3;
																else
																	loc_2144_ = rt_load_i32_from_u8(loc_2102_, loc_2135_, 0);
																	if rt_equal_i32(loc_2144_, 0) then
																		loc_2143_ = 3;
																	else
																		loc_2143_ = loc_2117_;
																		loc_2144_ = loc_2136_;
																		loc_2143_ = 4;
																		loc_2136_ = 0;
																		loc_2117_ = 3;
																	end
																end
															end
														else
															loc_2143_ = 4;
														end
														if (loc_2143_) >= 0 and (loc_2143_) < 4 then
															if (loc_2143_) < 2 then
																if (loc_2143_) < 1 then
																	loc_2143_ = loc_2136_;
																	loc_2136_ = loc_2117_;
																	loc_2143_ = loc_2099_;
																	loc_2110_[1](loc_2112_, 32, loc_2130_, loc_2135_, rt_exclusive_or_i32(loc_2141_, 8192), loc_2143_)
																	if rt_greater_than_s32(loc_2130_, loc_2135_) then
																		loc_2143_ = loc_2135_;
																		loc_2135_ = loc_2130_;
																	else
																		loc_2136_ = loc_2130_;
																		loc_2143_ = loc_2135_;
																		loc_2135_ = loc_2143_;
																	end
																	loc_2111_ = 2;
																	loc_2136_ = 1;
																	loc_2117_ = 65535;
																else
																	loc_2143_ = loc_2140_;
																	if rt_greater_than_equal_u64(loc_2133_, into_bits_i64(0, 1)) then
																		loc_2140_ = loc_2128_;
																		loc_2128_ = loc_2140_;
																		repeat
																			rt_yield_budget = rt_yield_budget - 1
																			if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																			loc_2143_ = loc_2135_;
																			loc_2135_ = loc_2134_;
																			loc_2140_ = bit32_or(loc_2140_ + -1, 0);
																			loc_2111_ = rt_divide_u64(loc_2133_, into_bits_i64(10, 0));
																			rt_store_i32_into_i8(loc_2102_, loc_2140_, 0, rt_or_i32(rt_low_subtract_i64(rt_narrow_i64(loc_2133_), rt_low_multiply_i64(rt_narrow_i64(loc_2111_), 10)), 48))
																			loc_2143_ = (rt_greater_than_u64(loc_2133_, into_bits_i64(4294967295, 9)) and 1 or 0);
																			loc_2135_ = loc_2143_;
																			loc_2133_ = loc_2111_;
																			loc_2134_ = loc_2111_;
																		until loc_2143_ == 0
																	else
																		loc_2140_ = loc_2128_;
																		loc_2143_ = loc_2133_;
																		loc_2128_ = loc_2140_;
																		loc_2133_ = loc_2143_;
																		loc_2134_ = loc_2143_;
																	end
																	if rt_equal_i64_constant(loc_2134_, 0, 0) then
																		loc_2111_ = 0;
																	else
																		loc_2143_ = loc_2135_;
																		loc_2135_ = rt_narrow_i64(loc_2134_);
																		repeat
																			rt_yield_budget = rt_yield_budget - 1
																			if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																			loc_2143_ = loc_2138_;
																			loc_2138_ = loc_2135_;
																			loc_2140_ = bit32_or(loc_2140_ + -1, 0);
																			loc_2143_ = rt_divide_u32(loc_2138_, 10);
																			rt_store_i32_into_i8(loc_2102_, loc_2140_, 0, rt_or_i32(bit32_or(loc_2138_ - rt_multiply_i32(loc_2143_, 10), 0), 48))
																			loc_2135_ = loc_2143_;
																			loc_2111_ = (rt_greater_than_u32(loc_2138_, 9) and 1 or 0);
																			loc_2138_ = loc_2111_;
																		until loc_2111_ == 0
																		loc_2111_ = 0;
																	end
																end
															elseif (loc_2143_) > 2 then
																loc_2111_ = 1;
															else
																loc_2111_ = 0;
															end
														else
															loc_2111_ = 2;
														end
														if (loc_2111_) >= 0 and (loc_2111_) < 2 then
															if (loc_2111_) < 1 then
																if rt_not_equal_i32(rt_and_i32(loc_2131_, (rt_less_than_s32(loc_2142_, 0) and 1 or 0)), 0) then
																	loc_2117_, loc_2141_ = loc_2141_, loc_2117_;
																	loc_2136_, loc_2142_ = loc_2142_, loc_2136_;
																	loc_2142_ = 1;
																	loc_2136_ = 0;
																	loc_2117_ = 13;
																else
																	loc_2117_, loc_2141_ = loc_2141_, loc_2117_;
																	loc_2136_, loc_2142_ = loc_2142_, loc_2136_;
																	loc_2137_ = rt_and_i32(loc_2117_, -65537);
																	if rt_not_equal_i32(loc_2131_, 0) then
																		loc_2117_, loc_2141_ = loc_2141_, loc_2117_;
																		loc_2136_, loc_2142_ = loc_2142_, loc_2136_;
																	else
																		loc_2117_, loc_2141_ = loc_2141_, loc_2117_;
																		loc_2136_, loc_2142_ = loc_2142_, loc_2136_;
																		loc_2137_ = loc_2141_;
																	end
																	loc_2133_ = rt_load_i64(loc_2102_, loc_2103_, 40);
																	if rt_not_equal_i64_constant(loc_2133_, 0, 0) then
																		loc_2141_ = 0;
																	else
																		loc_2141_ = loc_2138_;
																		loc_2138_ = 0;
																		if rt_not_equal_i32(loc_2142_, 0) then
																			loc_2141_ = 0;
																		else
																			loc_2141_ = loc_2135_;
																			loc_2135_ = loc_2140_;
																			loc_2140_ = loc_2128_;
																			loc_2141_ = 1;
																			loc_2128_ = loc_2140_;
																			loc_2135_ = loc_2140_;
																		end
																	end
																	if rt_not_equal_i32(loc_2141_, 0) then
																		loc_2142_ = 0;
																	else
																		loc_2141_ = loc_2135_;
																		loc_2141_ = bit32_or(bit32_or(loc_2128_ - loc_2140_, 0) + (rt_equal_i64_constant(loc_2133_, 0, 0) and 1 or 0), 0);
																		if rt_greater_than_s32(loc_2142_, loc_2141_) then
																			loc_2135_ = loc_2128_;
																			loc_2138_ = loc_2142_;
																			loc_2142_ = loc_2141_;
																		else
																			loc_2135_ = loc_2128_;
																			loc_2141_, loc_2142_ = loc_2142_, loc_2141_;
																			loc_2138_ = loc_2142_;
																		end
																		loc_2142_ = 0;
																		loc_2128_ = loc_2135_;
																	end
																end
															else
																loc_2142_ = 0;
															end
														else
															loc_2142_ = 1;
														end
														if not (rt_not_equal_i32(loc_2142_, 0)) then
															loc_2141_ = loc_2117_;
															loc_2142_ = loc_2136_;
															loc_2136_ = loc_2131_;
															loc_2142_ = bit32_or(loc_2135_ - loc_2140_, 0);
															if rt_greater_than_s32(loc_2138_, loc_2142_) then
																loc_2131_ = loc_2138_;
																loc_2136_ = loc_2137_;
																loc_2137_ = loc_2138_;
																loc_2138_ = loc_2142_;
															else
																loc_2136_ = loc_2137_;
																loc_2137_ = loc_2138_;
																loc_2141_ = loc_2138_;
																loc_2138_ = loc_2142_;
																loc_2131_ = loc_2142_;
															end
															if rt_greater_than_s32(loc_2131_, rt_exclusive_or_i32(loc_2129_, 2147483647)) then
																loc_2136_ = 0;
																loc_2117_ = 21;
															else
																loc_2142_ = loc_2135_;
																loc_2141_ = bit32_or(loc_2129_ + loc_2131_, 0);
																if rt_greater_than_s32(loc_2130_, loc_2141_) then
																	loc_2135_ = loc_2130_;
																	loc_2142_ = loc_2139_;
																	loc_2139_ = loc_2141_;
																else
																	loc_2135_ = loc_2130_;
																	loc_2142_ = loc_2139_;
																	loc_2139_ = loc_2141_;
																	loc_2135_ = loc_2141_;
																end
																if rt_greater_than_u32(loc_2135_, loc_2142_) then
																	loc_2136_ = 0;
																	loc_2117_ = 22;
																else
																	loc_2142_ = rt_and_i32(loc_2136_, 73728);
																	if rt_not_equal_i32(loc_2142_, 0) then
																		loc_2136_ = loc_2137_;
																		loc_2137_ = loc_2138_;
																		loc_2138_ = loc_2140_;
																		loc_2140_ = loc_2139_;
																		loc_2139_ = loc_2142_;
																	else
																		loc_2136_ = loc_2137_;
																		loc_2137_ = loc_2138_;
																		loc_2138_ = loc_2140_;
																		loc_2140_ = loc_2139_;
																		loc_2139_ = loc_2142_;
																		if not (rt_less_than_equal_s32(loc_2130_, loc_2140_)) then
																			loc_2141_ = bit32_or(loc_2135_ - loc_2140_, 0);
																			loc_2111_ = (rt_less_than_u32(loc_2141_, 256) and 1 or 0);
																			loc_2142_ = 256;
																			if rt_not_equal_i32(loc_2111_, 0) then
																				loc_2117_ = loc_2141_;
																			else
																				loc_2117_ = loc_2141_;
																				loc_2141_ = loc_2142_;
																			end
																			if not (rt_equal_i32(loc_2141_, 0)) then
																				rt_memory_fill(loc_2102_, bit32_or(loc_2103_ + 96, 0), 32, loc_2141_)
																			end
																			if not (rt_not_equal_i32(loc_2111_, 0)) then
																				repeat
																					rt_yield_budget = rt_yield_budget - 1
																					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																					loc_2111_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																					if not (rt_not_equal_i32(rt_and_i32(loc_2111_, 32), 0)) then
																						loc_2111_ = loc_2099_;
																						loc_2099_ = loc_2104_;
																						loc_2104_ = loc_2099_;
																						loc_2111_ = loc_2099_[1](bit32_or(loc_2103_ + 96, 0), 256, loc_2112_, loc_2111_)
																					end
																					loc_2111_ = bit32_or(loc_2117_ + -256, 0);
																					loc_2117_ = loc_2111_;
																				until not (rt_greater_than_u32(loc_2111_, 255))
																			end
																			loc_2111_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																			if not (rt_not_equal_i32(rt_and_i32(loc_2111_, 32), 0)) then
																				loc_2111_ = loc_2099_;
																				loc_2099_ = loc_2104_;
																				loc_2104_ = loc_2099_;
																				loc_2117_ = loc_2099_[1](bit32_or(loc_2103_ + 96, 0), loc_2117_, loc_2112_, loc_2111_)
																			end
																		end
																	end
																	loc_2117_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																	if not (rt_not_equal_i32(rt_and_i32(loc_2117_, 32), 0)) then
																		loc_2111_ = loc_2104_;
																		loc_2104_ = loc_2111_;
																		loc_2117_ = loc_2099_;
																		loc_2117_ = loc_2111_[1](loc_2132_, loc_2129_, loc_2112_, loc_2117_)
																	end
																	if not (rt_not_equal_i32(loc_2139_, 65536)) then
																		if not (rt_less_than_equal_s32(loc_2130_, loc_2140_)) then
																			loc_2129_, loc_2132_ = loc_2132_, loc_2129_;
																			loc_2132_ = bit32_or(loc_2135_ - loc_2140_, 0);
																			loc_2129_ = (rt_less_than_u32(loc_2132_, 256) and 1 or 0);
																			loc_2111_ = 256;
																			if rt_not_equal_i32(loc_2129_, 0) then
																				loc_2117_ = loc_2132_;
																			else
																				loc_2117_ = loc_2132_;
																				loc_2132_ = loc_2111_;
																			end
																			if not (rt_equal_i32(loc_2132_, 0)) then
																				rt_memory_fill(loc_2102_, bit32_or(loc_2103_ + 96, 0), 48, loc_2132_)
																			end
																			if not (rt_not_equal_i32(loc_2129_, 0)) then
																				repeat
																					rt_yield_budget = rt_yield_budget - 1
																					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																					loc_2111_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																					if not (rt_not_equal_i32(rt_and_i32(loc_2111_, 32), 0)) then
																						loc_2111_ = loc_2099_;
																						loc_2099_ = loc_2104_;
																						loc_2104_ = loc_2099_;
																						loc_2111_ = loc_2099_[1](bit32_or(loc_2103_ + 96, 0), 256, loc_2112_, loc_2111_)
																					end
																					loc_2111_ = bit32_or(loc_2117_ + -256, 0);
																					loc_2117_ = loc_2111_;
																				until not (rt_greater_than_u32(loc_2111_, 255))
																			end
																			loc_2111_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																			if not (rt_not_equal_i32(rt_and_i32(loc_2111_, 32), 0)) then
																				loc_2111_ = loc_2099_;
																				loc_2099_ = loc_2104_;
																				loc_2104_ = loc_2099_;
																				loc_2117_ = loc_2099_[1](bit32_or(loc_2103_ + 96, 0), loc_2117_, loc_2112_, loc_2111_)
																			end
																		end
																	end
																	if not (rt_less_than_equal_s32(loc_2136_, loc_2137_)) then
																		loc_2131_ = bit32_or(loc_2131_ - loc_2137_, 0);
																		loc_2117_ = (rt_less_than_u32(loc_2131_, 256) and 1 or 0);
																		loc_2111_ = 256;
																		if rt_not_equal_i32(loc_2117_, 0) then
																			loc_2136_ = loc_2131_;
																		else
																			loc_2136_ = loc_2131_;
																			loc_2131_ = loc_2111_;
																		end
																		if not (rt_equal_i32(loc_2131_, 0)) then
																			rt_memory_fill(loc_2102_, bit32_or(loc_2103_ + 96, 0), 48, loc_2131_)
																		end
																		if not (rt_not_equal_i32(loc_2117_, 0)) then
																			repeat
																				rt_yield_budget = rt_yield_budget - 1
																				if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																				loc_2117_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																				if not (rt_not_equal_i32(rt_and_i32(loc_2117_, 32), 0)) then
																					loc_2111_ = loc_2104_;
																					loc_2104_ = loc_2111_;
																					loc_2117_ = loc_2099_;
																					loc_2117_ = loc_2111_[1](bit32_or(loc_2103_ + 96, 0), 256, loc_2112_, loc_2117_)
																				end
																				loc_2117_ = bit32_or(loc_2136_ + -256, 0);
																				loc_2136_ = loc_2117_;
																			until not (rt_greater_than_u32(loc_2117_, 255))
																		end
																		loc_2117_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																		if not (rt_not_equal_i32(rt_and_i32(loc_2117_, 32), 0)) then
																			loc_2111_ = loc_2104_;
																			loc_2104_ = loc_2111_;
																			loc_2117_ = loc_2099_;
																			loc_2136_ = loc_2111_[1](bit32_or(loc_2103_ + 96, 0), loc_2136_, loc_2112_, loc_2117_)
																		end
																	end
																	loc_2136_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																	if not (rt_not_equal_i32(rt_and_i32(loc_2136_, 32), 0)) then
																		loc_2117_ = loc_2104_;
																		loc_2104_ = loc_2117_;
																		loc_2136_ = loc_2099_;
																		loc_2138_ = loc_2117_[1](loc_2138_, loc_2137_, loc_2112_, loc_2136_)
																	end
																	if rt_not_equal_i32(loc_2139_, 8192) then
																		loc_2136_ = 1;
																		loc_2117_ = 65535;
																	else
																		if rt_less_than_equal_s32(loc_2130_, loc_2140_) then
																			loc_2136_ = 1;
																			loc_2117_ = 65535;
																		else
																			loc_2138_ = bit32_or(loc_2135_ - loc_2140_, 0);
																			loc_2139_ = (rt_less_than_u32(loc_2138_, 256) and 1 or 0);
																			loc_2137_ = 256;
																			if rt_not_equal_i32(loc_2139_, 0) then
																				loc_2140_ = loc_2138_;
																			else
																				loc_2140_ = loc_2138_;
																				loc_2138_ = loc_2137_;
																			end
																			if not (rt_equal_i32(loc_2138_, 0)) then
																				rt_memory_fill(loc_2102_, bit32_or(loc_2103_ + 96, 0), 32, loc_2138_)
																			end
																			if not (rt_not_equal_i32(loc_2139_, 0)) then
																				repeat
																					rt_yield_budget = rt_yield_budget - 1
																					if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																					loc_2139_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																					if not (rt_not_equal_i32(rt_and_i32(loc_2139_, 32), 0)) then
																						loc_2138_ = loc_2104_;
																						loc_2104_ = loc_2138_;
																						loc_2139_ = loc_2099_;
																						loc_2139_ = loc_2138_[1](bit32_or(loc_2103_ + 96, 0), 256, loc_2112_, loc_2139_)
																					end
																					loc_2139_ = bit32_or(loc_2140_ + -256, 0);
																					loc_2140_ = loc_2139_;
																				until not (rt_greater_than_u32(loc_2139_, 255))
																			end
																			loc_2139_ = rt_load_i32_from_u8(loc_2102_, loc_2112_, 0);
																			if rt_not_equal_i32(rt_and_i32(loc_2139_, 32), 0) then
																				loc_2136_ = 1;
																				loc_2117_ = 65535;
																			else
																				loc_2138_ = loc_2104_;
																				loc_2104_ = loc_2138_;
																				loc_2139_ = loc_2099_;
																				loc_2140_ = loc_2138_[1](bit32_or(loc_2103_ + 96, 0), loc_2140_, loc_2112_, loc_2139_)
																				loc_2136_ = 1;
																				loc_2117_ = 65535;
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
					loc_2111_ = loc_2136_;
				until loc_2136_ == 0
				if (loc_2117_) >= 0 and (loc_2117_) < 24 then
					if (loc_2117_) < 12 then
						if (loc_2117_) < 6 then
							if (loc_2117_) < 3 then
								if (loc_2117_) < 1 then
									rt_store_i32(loc_2102_, bit32_or(loc_2115_ + rt_shift_left_i32(loc_2129_, 2), 0), 0, loc_2135_)
									loc_2135_ = 1;
									loc_2111_ = 65535;
								elseif (loc_2117_) > 1 then
									loc_2135_ = 0;
									loc_2111_ = 1;
								else
									loc_2135_ = 0;
									loc_2111_ = 0;
								end
							elseif (loc_2117_) > 3 then
								if (loc_2117_) < 5 then
									loc_2135_ = 0;
									loc_2111_ = 3;
								else
									loc_2135_ = 0;
									loc_2111_ = 4;
								end
							else
								loc_2135_ = 0;
								loc_2111_ = 2;
							end
						elseif (loc_2117_) > 6 then
							if (loc_2117_) < 9 then
								if (loc_2117_) < 8 then
									loc_2135_ = 0;
									loc_2111_ = 4;
								else
									loc_2135_ = 0;
									loc_2111_ = 4;
								end
							elseif (loc_2117_) > 9 then
								if (loc_2117_) < 11 then
									loc_2135_ = 0;
									loc_2111_ = 5;
								else
									loc_2135_ = 0;
									loc_2111_ = 5;
								end
							else
								loc_2135_ = 0;
								loc_2111_ = 4;
							end
						else
							loc_2135_ = 0;
							loc_2111_ = 4;
						end
					elseif (loc_2117_) > 12 then
						if (loc_2117_) < 18 then
							if (loc_2117_) < 15 then
								if (loc_2117_) < 14 then
									loc_2135_ = 0;
									loc_2111_ = 5;
								else
									loc_2135_ = 0;
									loc_2111_ = 5;
								end
							elseif (loc_2117_) > 15 then
								if (loc_2117_) < 17 then
									loc_2135_ = 0;
									loc_2111_ = 5;
								else
									loc_2135_ = 0;
									loc_2111_ = 5;
								end
							else
								loc_2135_ = 0;
								loc_2111_ = 5;
							end
						elseif (loc_2117_) > 18 then
							if (loc_2117_) < 21 then
								if (loc_2117_) < 20 then
									loc_2135_ = 0;
									loc_2111_ = 5;
								else
									loc_2135_ = 0;
									loc_2111_ = 5;
								end
							elseif (loc_2117_) > 21 then
								if (loc_2117_) < 23 then
									loc_2135_ = 0;
									loc_2111_ = 5;
								else
									loc_2135_ = 0;
									loc_2111_ = 6;
								end
							else
								loc_2135_ = 0;
								loc_2111_ = 5;
							end
						else
							loc_2135_ = 0;
							loc_2111_ = 5;
						end
					else
						loc_2135_ = 0;
						loc_2111_ = 5;
					end
				else
					loc_2135_ = 0;
					loc_2111_ = 6;
				end
				loc_2117_ = loc_2135_;
			until loc_2135_ == 0
			if (loc_2111_) >= 0 and (loc_2111_) < 6 then
				if (loc_2111_) < 3 then
					if (loc_2111_) < 1 then
						loc_2111_, loc_2116_ = loc_2116_, loc_2111_;
						loc_2112_, loc_2115_ = loc_2115_, loc_2112_;
						loc_2113_, loc_2114_ = loc_2114_, loc_2113_;
						loc_2111_ = 1;
					elseif (loc_2111_) > 1 then
						loc_2111_, loc_2116_ = loc_2116_, loc_2111_;
						loc_2112_, loc_2115_ = loc_2115_, loc_2112_;
						loc_2113_, loc_2114_ = loc_2114_, loc_2113_;
						loc_2111_ = 1;
					else
						loc_2111_, loc_2116_ = loc_2116_, loc_2111_;
						loc_2112_, loc_2115_ = loc_2115_, loc_2112_;
						loc_2113_, loc_2114_ = loc_2114_, loc_2113_;
						loc_2111_ = 3;
						loc_2100_ = 0;
					end
				elseif (loc_2111_) > 3 then
					if (loc_2111_) < 5 then
						loc_2111_, loc_2116_ = loc_2116_, loc_2111_;
						loc_2112_, loc_2115_ = loc_2115_, loc_2112_;
						loc_2113_, loc_2114_ = loc_2114_, loc_2113_;
						loc_2111_ = 0;
					else
						loc_2111_, loc_2116_ = loc_2116_, loc_2111_;
						loc_2112_, loc_2115_ = loc_2115_, loc_2112_;
						loc_2113_, loc_2114_ = loc_2114_, loc_2113_;
						loc_2111_ = 1;
					end
				else
					if rt_not_equal_i32(loc_2112_, 0) then
						loc_2112_ = loc_2116_;
						loc_2116_ = loc_2111_;
						loc_2113_, loc_2115_ = loc_2115_, loc_2113_;
						loc_2111_ = 3;
					else
						loc_2112_ = loc_2116_;
						loc_2116_ = loc_2111_;
						loc_2113_, loc_2115_ = loc_2115_, loc_2113_;
						if rt_not_equal_i32(loc_2112_, 0) then
							loc_2111_ = loc_2115_;
							loc_2112_ = loc_2114_;
							loc_2114_ = loc_2113_;
							loc_2115_ = loc_2099_;
							loc_2100_, loc_2109_ = loc_2109_, loc_2100_;
							loc_2113_ = buffer_read_i32(loc_2102_[1], loc_2114_, 4);
							if rt_not_equal_i32(loc_2113_, 0) then
								loc_2100_[1](bit32_or(loc_2112_ + 8, 0), loc_2113_, loc_2111_, loc_2115_)
								loc_2113_ = buffer_read_i32(loc_2102_[1], loc_2114_, 8);
								if rt_not_equal_i32(loc_2113_, 0) then
									loc_2100_[1](bit32_or(loc_2112_ + 16, 0), loc_2113_, loc_2111_, loc_2115_)
									loc_2113_ = buffer_read_i32(loc_2102_[1], loc_2114_, 12);
									if rt_not_equal_i32(loc_2113_, 0) then
										loc_2100_[1](bit32_or(loc_2112_ + 24, 0), loc_2113_, loc_2111_, loc_2115_)
										loc_2113_ = buffer_read_i32(loc_2102_[1], loc_2114_, 16);
										if rt_not_equal_i32(loc_2113_, 0) then
											loc_2100_[1](bit32_or(loc_2112_ + 32, 0), loc_2113_, loc_2111_, loc_2115_)
											loc_2113_ = buffer_read_i32(loc_2102_[1], loc_2114_, 20);
											if rt_not_equal_i32(loc_2113_, 0) then
												loc_2100_[1](bit32_or(loc_2112_ + 40, 0), loc_2113_, loc_2111_, loc_2115_)
												loc_2113_ = buffer_read_i32(loc_2102_[1], loc_2114_, 24);
												if rt_not_equal_i32(loc_2113_, 0) then
													loc_2100_[1](bit32_or(loc_2112_ + 48, 0), loc_2113_, loc_2111_, loc_2115_)
													loc_2113_ = buffer_read_i32(loc_2102_[1], loc_2114_, 28);
													if rt_not_equal_i32(loc_2113_, 0) then
														loc_2100_[1](bit32_or(loc_2112_ + 56, 0), loc_2113_, loc_2111_, loc_2115_)
														loc_2113_ = buffer_read_i32(loc_2102_[1], loc_2114_, 32);
														if rt_not_equal_i32(loc_2113_, 0) then
															loc_2100_[1](bit32_or(loc_2112_ + 64, 0), loc_2113_, loc_2111_, loc_2115_)
															loc_2115_ = buffer_read_i32(loc_2102_[1], loc_2114_, 36);
															if rt_not_equal_i32(loc_2115_, 0) then
																loc_2109_ = loc_2100_;
																loc_2100_[1](bit32_or(loc_2112_ + 72, 0), loc_2115_, loc_2111_, loc_2113_)
																loc_2113_ = 1;
																loc_2100_ = 1;
															else
																loc_2109_, loc_2112_ = loc_2112_, loc_2109_;
																loc_2112_, loc_2113_ = loc_2113_, loc_2112_;
																loc_2113_, loc_2111_ = loc_2111_, loc_2113_;
																loc_2109_ = loc_2100_;
																loc_2113_ = 0;
																loc_2115_ = 9;
																loc_2100_ = loc_2111_;
																loc_2099_ = loc_2112_;
															end
														else
															loc_2109_, loc_2112_ = loc_2112_, loc_2109_;
															loc_2112_, loc_2115_ = loc_2115_, loc_2112_;
															loc_2115_, loc_2113_ = loc_2113_, loc_2115_;
															loc_2113_, loc_2111_ = loc_2111_, loc_2113_;
															loc_2109_ = loc_2100_;
															loc_2113_ = 0;
															loc_2115_ = 8;
															loc_2100_ = loc_2111_;
															loc_2099_ = loc_2112_;
														end
													else
														loc_2109_, loc_2112_ = loc_2112_, loc_2109_;
														loc_2112_, loc_2115_ = loc_2115_, loc_2112_;
														loc_2115_, loc_2113_ = loc_2113_, loc_2115_;
														loc_2113_, loc_2111_ = loc_2111_, loc_2113_;
														loc_2109_ = loc_2100_;
														loc_2113_ = 0;
														loc_2115_ = 7;
														loc_2100_ = loc_2111_;
														loc_2099_ = loc_2112_;
													end
												else
													loc_2109_, loc_2112_ = loc_2112_, loc_2109_;
													loc_2112_, loc_2115_ = loc_2115_, loc_2112_;
													loc_2115_, loc_2113_ = loc_2113_, loc_2115_;
													loc_2113_, loc_2111_ = loc_2111_, loc_2113_;
													loc_2109_ = loc_2100_;
													loc_2113_ = 0;
													loc_2115_ = 6;
													loc_2100_ = loc_2111_;
													loc_2099_ = loc_2112_;
												end
											else
												loc_2109_, loc_2112_ = loc_2112_, loc_2109_;
												loc_2112_, loc_2115_ = loc_2115_, loc_2112_;
												loc_2115_, loc_2113_ = loc_2113_, loc_2115_;
												loc_2113_, loc_2111_ = loc_2111_, loc_2113_;
												loc_2109_ = loc_2100_;
												loc_2113_ = 0;
												loc_2115_ = 5;
												loc_2100_ = loc_2111_;
												loc_2099_ = loc_2112_;
											end
										else
											loc_2109_, loc_2112_ = loc_2112_, loc_2109_;
											loc_2112_, loc_2115_ = loc_2115_, loc_2112_;
											loc_2115_, loc_2113_ = loc_2113_, loc_2115_;
											loc_2113_, loc_2111_ = loc_2111_, loc_2113_;
											loc_2109_ = loc_2100_;
											loc_2113_ = 0;
											loc_2115_ = 4;
											loc_2100_ = loc_2111_;
											loc_2099_ = loc_2112_;
										end
									else
										loc_2109_, loc_2112_ = loc_2112_, loc_2109_;
										loc_2112_, loc_2115_ = loc_2115_, loc_2112_;
										loc_2115_, loc_2113_ = loc_2113_, loc_2115_;
										loc_2113_, loc_2111_ = loc_2111_, loc_2113_;
										loc_2109_ = loc_2100_;
										loc_2113_ = 0;
										loc_2115_ = 3;
										loc_2100_ = loc_2111_;
										loc_2099_ = loc_2112_;
									end
								else
									loc_2109_, loc_2112_ = loc_2112_, loc_2109_;
									loc_2112_, loc_2115_ = loc_2115_, loc_2112_;
									loc_2115_, loc_2113_ = loc_2113_, loc_2115_;
									loc_2113_, loc_2111_ = loc_2111_, loc_2113_;
									loc_2109_ = loc_2100_;
									loc_2113_ = 0;
									loc_2115_ = 2;
									loc_2100_ = loc_2111_;
									loc_2099_ = loc_2112_;
								end
							else
								loc_2109_, loc_2112_ = loc_2112_, loc_2109_;
								loc_2112_, loc_2115_ = loc_2115_, loc_2112_;
								loc_2115_, loc_2113_ = loc_2113_, loc_2115_;
								loc_2113_, loc_2111_ = loc_2111_, loc_2113_;
								loc_2109_ = loc_2100_;
								loc_2113_ = 0;
								loc_2115_ = 1;
								loc_2100_ = loc_2111_;
								loc_2099_ = loc_2112_;
							end
							if rt_not_equal_i32(loc_2113_, 0) then
								loc_2111_ = 3;
							else
								loc_2115_ = rt_shift_left_i32(loc_2115_, 2);
								repeat
									rt_yield_budget = rt_yield_budget - 1
									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
									loc_2116_ = buffer_read_i32(loc_2102_[1], bit32_or(loc_2114_ + loc_2115_, 0), 0);
									if rt_not_equal_i32(loc_2116_, 0) then
										loc_2113_ = 0;
										loc_2116_ = 1;
									else
										loc_2115_ = bit32_or(loc_2115_ + 4, 0);
										if rt_not_equal_i32(loc_2115_, 40) then
											loc_2113_ = 1;
											loc_2116_ = 65535;
										else
											loc_2113_ = 0;
											loc_2116_ = 0;
										end
									end
								until loc_2113_ == 0
								if rt_not_equal_i32(loc_2116_, 0) then
									loc_2111_ = 0;
								else
									loc_2116_ = loc_2100_;
									loc_2111_ = 3;
									loc_2100_ = 1;
								end
							end
						else
							loc_2111_ = loc_2100_;
							loc_2100_ = loc_2109_;
							loc_2112_ = loc_2113_;
							loc_2113_ = loc_2114_;
							loc_2114_ = loc_2115_;
							loc_2115_ = loc_2099_;
							loc_2109_ = loc_2100_;
							loc_2111_ = 3;
							loc_2100_ = 0;
							loc_2099_ = loc_2115_;
						end
					end
				end
			else
				loc_2111_ = 2;
			end
			if (loc_2111_) >= 0 and (loc_2111_) < 3 then
				if (loc_2111_) < 1 then
					rt_store_i32(loc_2102_, 0, 27520, 28)
					loc_2111_ = 0;
				elseif (loc_2111_) > 1 then
					loc_2111_ = 0;
				else
					rt_store_i32(loc_2102_, 0, 27520, 61)
					loc_2111_ = 0;
				end
			else
				loc_2111_ = 1;
			end
			if not (rt_not_equal_i32(loc_2111_, 0)) then
				loc_2100_ = -1;
			end
			loc_2101_[1] = bit32_or(loc_2103_ + 864, 0);
			return loc_2100_, loc_2099_
		end), "i32,i32,i32,i32,i32->i32")
	end)(module_locals[122], module_locals[144], module_locals[145], module_locals[147], module_locals[148], module_locals[152], module_locals[153], module_locals[164], module_locals[3]);
	do (function() --[[spider:chunk]]
	module_locals[154] = { nil };
	module_locals[152][1] = (function(loc_2154_, loc_2155_)
		return rt_function_type(--[[fn:pop_arg]](function(loc_2156_, loc_2157_, loc_2158_, loc_2159_)
			local loc_2160_, loc_2161_, loc_2162_, loc_2163_, loc_2164_, loc_2165_
			loc_2165_ = bit32_or(loc_2157_ + -9, 0);
			if (loc_2165_) >= 0 and (loc_2165_) < 18 then
				if (loc_2165_) < 9 then
					if (loc_2165_) < 4 then
						if (loc_2165_) < 2 then
							if (loc_2165_) < 1 then
								loc_2160_ = loc_2159_;
								loc_2161_ = loc_2155_;
								loc_2162_ = loc_2154_;
								loc_2163_ = loc_2156_;
								loc_2164_ = loc_2158_;
								loc_2165_ = buffer_read_i32(loc_2161_[1], loc_2164_, 0);
								rt_store_i32(loc_2161_, loc_2164_, 0, bit32_or(loc_2165_ + 4, 0))
								loc_2165_ = buffer_read_i32(loc_2161_[1], loc_2165_, 0);
								rt_store_i32(loc_2161_, loc_2163_, 0, loc_2165_)
								loc_2163_ = 0;
							else
								loc_2160_ = loc_2159_;
								loc_2161_ = loc_2155_;
								loc_2162_ = loc_2154_;
								loc_2163_ = loc_2156_;
								loc_2164_ = loc_2158_;
								loc_2165_ = buffer_read_i32(loc_2161_[1], loc_2164_, 0);
								rt_store_i32(loc_2161_, loc_2164_, 0, bit32_or(loc_2165_ + 4, 0))
								loc_2165_ = rt_load_i64_from_s32(loc_2161_, loc_2165_, 0);
								rt_store_i64(loc_2161_, loc_2163_, 0, loc_2165_)
								loc_2163_ = 1;
							end
						elseif (loc_2165_) > 2 then
							loc_2160_ = loc_2159_;
							loc_2161_ = loc_2155_;
							loc_2162_ = loc_2154_;
							loc_2163_ = loc_2156_;
							loc_2164_ = loc_2158_;
							loc_2165_ = buffer_read_i32(loc_2161_[1], loc_2164_, 0);
							loc_2165_ = rt_and_i32(bit32_or(loc_2165_ + 7, 0), -8);
							rt_store_i32(loc_2161_, loc_2164_, 0, bit32_or(loc_2165_ + 8, 0))
							loc_2165_ = rt_load_i64(loc_2161_, loc_2165_, 0);
							rt_store_i64(loc_2161_, loc_2163_, 0, loc_2165_)
							loc_2163_ = 1;
						else
							loc_2160_ = loc_2159_;
							loc_2161_ = loc_2155_;
							loc_2162_ = loc_2154_;
							loc_2163_ = loc_2156_;
							loc_2164_ = loc_2158_;
							loc_2165_ = buffer_read_i32(loc_2161_[1], loc_2164_, 0);
							rt_store_i32(loc_2161_, loc_2164_, 0, bit32_or(loc_2165_ + 4, 0))
							loc_2165_ = rt_load_i64_from_u32(loc_2161_, loc_2165_, 0);
							rt_store_i64(loc_2161_, loc_2163_, 0, loc_2165_)
							loc_2163_ = 1;
						end
					elseif (loc_2165_) > 4 then
						if (loc_2165_) < 7 then
							if (loc_2165_) < 6 then
								loc_2160_ = loc_2159_;
								loc_2161_ = loc_2155_;
								loc_2162_ = loc_2154_;
								loc_2163_ = loc_2156_;
								loc_2164_ = loc_2158_;
								loc_2165_ = buffer_read_i32(loc_2161_[1], loc_2164_, 0);
								rt_store_i32(loc_2161_, loc_2164_, 0, bit32_or(loc_2165_ + 4, 0))
								loc_2165_ = rt_load_i64_from_u32(loc_2161_, loc_2165_, 0);
								rt_store_i64(loc_2161_, loc_2163_, 0, loc_2165_)
								loc_2163_ = 1;
							else
								loc_2160_ = loc_2159_;
								loc_2161_ = loc_2155_;
								loc_2162_ = loc_2154_;
								loc_2163_ = loc_2156_;
								loc_2164_ = loc_2158_;
								loc_2165_ = buffer_read_i32(loc_2161_[1], loc_2164_, 0);
								rt_store_i32(loc_2161_, loc_2164_, 0, bit32_or(loc_2165_ + 4, 0))
								loc_2165_ = rt_load_i64_from_s16(loc_2161_, loc_2165_, 0);
								rt_store_i64(loc_2161_, loc_2163_, 0, loc_2165_)
								loc_2163_ = 1;
							end
						elseif (loc_2165_) > 7 then
							loc_2160_ = loc_2159_;
							loc_2161_ = loc_2155_;
							loc_2162_ = loc_2154_;
							loc_2163_ = loc_2156_;
							loc_2164_ = loc_2158_;
							loc_2165_ = buffer_read_i32(loc_2161_[1], loc_2164_, 0);
							rt_store_i32(loc_2161_, loc_2164_, 0, bit32_or(loc_2165_ + 4, 0))
							loc_2165_ = rt_load_i64_from_s8(loc_2161_, loc_2165_, 0);
							rt_store_i64(loc_2161_, loc_2163_, 0, loc_2165_)
							loc_2163_ = 1;
						else
							loc_2160_ = loc_2159_;
							loc_2161_ = loc_2155_;
							loc_2162_ = loc_2154_;
							loc_2163_ = loc_2156_;
							loc_2164_ = loc_2158_;
							loc_2165_ = buffer_read_i32(loc_2161_[1], loc_2164_, 0);
							rt_store_i32(loc_2161_, loc_2164_, 0, bit32_or(loc_2165_ + 4, 0))
							loc_2165_ = rt_load_i64_from_u16(loc_2161_, loc_2165_, 0);
							rt_store_i64(loc_2161_, loc_2163_, 0, loc_2165_)
							loc_2163_ = 1;
						end
					else
						loc_2160_ = loc_2159_;
						loc_2161_ = loc_2155_;
						loc_2162_ = loc_2154_;
						loc_2163_ = loc_2156_;
						loc_2164_ = loc_2158_;
						loc_2165_ = buffer_read_i32(loc_2161_[1], loc_2164_, 0);
						rt_store_i32(loc_2161_, loc_2164_, 0, bit32_or(loc_2165_ + 4, 0))
						loc_2165_ = rt_load_i64_from_s32(loc_2161_, loc_2165_, 0);
						rt_store_i64(loc_2161_, loc_2163_, 0, loc_2165_)
						loc_2163_ = 1;
					end
				elseif (loc_2165_) > 9 then
					if (loc_2165_) < 14 then
						if (loc_2165_) < 12 then
							if (loc_2165_) < 11 then
								loc_2160_ = loc_2159_;
								loc_2161_ = loc_2155_;
								loc_2162_ = loc_2154_;
								loc_2163_ = loc_2156_;
								loc_2164_ = loc_2158_;
								loc_2165_ = buffer_read_i32(loc_2161_[1], loc_2164_, 0);
								loc_2165_ = rt_and_i32(bit32_or(loc_2165_ + 7, 0), -8);
								rt_store_i32(loc_2161_, loc_2164_, 0, bit32_or(loc_2165_ + 8, 0))
								loc_2165_ = rt_load_i64(loc_2161_, loc_2165_, 0);
								rt_store_i64(loc_2161_, loc_2163_, 0, loc_2165_)
								loc_2163_ = 1;
							else
								loc_2160_ = loc_2159_;
								loc_2161_ = loc_2155_;
								loc_2162_ = loc_2154_;
								loc_2163_ = loc_2156_;
								loc_2164_ = loc_2158_;
								loc_2165_ = buffer_read_i32(loc_2161_[1], loc_2164_, 0);
								rt_store_i32(loc_2161_, loc_2164_, 0, bit32_or(loc_2165_ + 4, 0))
								loc_2165_ = rt_load_i64_from_u32(loc_2161_, loc_2165_, 0);
								rt_store_i64(loc_2161_, loc_2163_, 0, loc_2165_)
								loc_2163_ = 1;
							end
						elseif (loc_2165_) > 12 then
							loc_2160_ = loc_2159_;
							loc_2161_ = loc_2155_;
							loc_2162_ = loc_2154_;
							loc_2163_ = loc_2156_;
							loc_2164_ = loc_2158_;
							loc_2165_ = buffer_read_i32(loc_2161_[1], loc_2164_, 0);
							loc_2165_ = rt_and_i32(bit32_or(loc_2165_ + 7, 0), -8);
							rt_store_i32(loc_2161_, loc_2164_, 0, bit32_or(loc_2165_ + 8, 0))
							loc_2165_ = rt_load_i64(loc_2161_, loc_2165_, 0);
							rt_store_i64(loc_2161_, loc_2163_, 0, loc_2165_)
							loc_2163_ = 1;
						else
							loc_2160_ = loc_2159_;
							loc_2161_ = loc_2155_;
							loc_2162_ = loc_2154_;
							loc_2163_ = loc_2156_;
							loc_2164_ = loc_2158_;
							loc_2165_ = buffer_read_i32(loc_2161_[1], loc_2164_, 0);
							loc_2165_ = rt_and_i32(bit32_or(loc_2165_ + 7, 0), -8);
							rt_store_i32(loc_2161_, loc_2164_, 0, bit32_or(loc_2165_ + 8, 0))
							loc_2165_ = rt_load_i64(loc_2161_, loc_2165_, 0);
							rt_store_i64(loc_2161_, loc_2163_, 0, loc_2165_)
							loc_2163_ = 1;
						end
					elseif (loc_2165_) > 14 then
						if (loc_2165_) < 16 then
							loc_2160_ = loc_2159_;
							loc_2161_ = loc_2155_;
							loc_2162_ = loc_2154_;
							loc_2163_ = loc_2156_;
							loc_2164_ = loc_2158_;
							loc_2165_ = buffer_read_i32(loc_2161_[1], loc_2164_, 0);
							rt_store_i32(loc_2161_, loc_2164_, 0, bit32_or(loc_2165_ + 4, 0))
							loc_2165_ = rt_load_i64_from_u32(loc_2161_, loc_2165_, 0);
							rt_store_i64(loc_2161_, loc_2163_, 0, loc_2165_)
							loc_2163_ = 1;
						elseif (loc_2165_) > 16 then
							loc_2160_ = loc_2159_;
							loc_2161_ = loc_2155_;
							loc_2162_ = loc_2158_;
							loc_2163_ = loc_2154_;
							loc_2164_ = loc_2156_;
							loc_2162_ = loc_2163_;
							loc_2164_ = loc_2160_;
							loc_2163_[1](loc_2164_)
							loc_2163_ = 1;
							loc_2164_ = error('unreachable code');
						else
							loc_2160_ = loc_2159_;
							loc_2161_ = loc_2155_;
							loc_2162_ = loc_2154_;
							loc_2163_ = loc_2156_;
							loc_2165_ = loc_2158_;
							loc_2164_ = buffer_read_i32(loc_2161_[1], loc_2165_, 0);
							loc_2164_ = rt_and_i32(bit32_or(loc_2164_ + 7, 0), -8);
							rt_store_i32(loc_2161_, loc_2165_, 0, bit32_or(loc_2164_ + 8, 0))
							loc_2164_ = rt_load_f64(loc_2161_, loc_2164_, 0);
							rt_store_f64(loc_2161_, loc_2163_, 0, loc_2164_)
							loc_2163_ = 1;
						end
					else
						loc_2160_ = loc_2159_;
						loc_2161_ = loc_2155_;
						loc_2162_ = loc_2154_;
						loc_2163_ = loc_2156_;
						loc_2164_ = loc_2158_;
						loc_2165_ = buffer_read_i32(loc_2161_[1], loc_2164_, 0);
						rt_store_i32(loc_2161_, loc_2164_, 0, bit32_or(loc_2165_ + 4, 0))
						loc_2165_ = rt_load_i64_from_s32(loc_2161_, loc_2165_, 0);
						rt_store_i64(loc_2161_, loc_2163_, 0, loc_2165_)
						loc_2163_ = 1;
					end
				else
					loc_2160_ = loc_2159_;
					loc_2161_ = loc_2155_;
					loc_2162_ = loc_2154_;
					loc_2163_ = loc_2156_;
					loc_2164_ = loc_2158_;
					loc_2165_ = buffer_read_i32(loc_2161_[1], loc_2164_, 0);
					rt_store_i32(loc_2161_, loc_2164_, 0, bit32_or(loc_2165_ + 4, 0))
					loc_2165_ = rt_load_i64_from_u8(loc_2161_, loc_2165_, 0);
					rt_store_i64(loc_2161_, loc_2163_, 0, loc_2165_)
					loc_2163_ = 1;
				end
			else
				loc_2160_ = loc_2159_;
				loc_2161_ = loc_2155_;
				loc_2162_ = loc_2154_;
				loc_2163_ = loc_2156_;
				loc_2164_ = loc_2158_;
				loc_2163_ = 0;
			end
			if rt_not_equal_i32(loc_2163_, 0) then
			end
			return loc_2160_
		end), "i32,i32,i32->")
	end)(module_locals[154], module_locals[3]);
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[153][1] = (function(loc_2166_, loc_2167_, loc_2168_)
		return rt_function_type(--[[fn:pad]](function(loc_2169_, loc_2170_, loc_2171_, loc_2172_, loc_2173_, loc_2174_)
			local loc_2175_, loc_2176_, loc_2177_, loc_2178_, loc_2179_, loc_2180_, loc_2181_, loc_2182_, loc_2183_, loc_2184_, loc_2185_
			loc_2185_ = loc_2167_[1];
			loc_2176_ = loc_2167_;
			loc_2178_ = bit32_or(loc_2185_ - 256, 0);
			loc_2176_[1] = loc_2178_;
			if rt_less_than_equal_s32(loc_2171_, loc_2172_) then
				loc_2175_ = loc_2174_;
				loc_2177_ = loc_2168_;
				loc_2179_ = loc_2166_;
				loc_2180_ = loc_2169_;
				loc_2181_ = loc_2170_;
				loc_2182_ = loc_2171_;
				loc_2183_ = loc_2172_;
				loc_2184_ = loc_2173_;
			else
				loc_2175_ = loc_2174_;
				loc_2177_ = loc_2168_;
				loc_2179_ = loc_2166_;
				loc_2180_ = loc_2169_;
				loc_2181_ = loc_2170_;
				loc_2182_ = loc_2171_;
				loc_2183_ = loc_2172_;
				loc_2184_ = loc_2173_;
				if rt_not_equal_i32(rt_and_i32(loc_2184_, 73728), 0) then
					loc_2184_ = loc_2180_;
					loc_2181_, loc_2183_ = loc_2183_, loc_2181_;
				else
					loc_2184_ = loc_2180_;
					loc_2181_, loc_2183_ = loc_2183_, loc_2181_;
					loc_2180_ = bit32_or(loc_2182_ - loc_2181_, 0);
					loc_2182_ = (rt_less_than_u32(loc_2180_, 256) and 1 or 0);
					loc_2185_ = 256;
					if rt_not_equal_i32(loc_2182_, 0) then
						loc_2181_ = loc_2183_;
						loc_2183_ = loc_2180_;
					else
						loc_2181_ = loc_2183_;
						loc_2183_ = loc_2180_;
						loc_2180_ = loc_2185_;
					end
					if not (rt_equal_i32(loc_2180_, 0)) then
						rt_memory_fill(loc_2177_, loc_2178_, loc_2181_, loc_2180_)
					end
					if not (rt_not_equal_i32(loc_2182_, 0)) then
						repeat
							rt_yield_budget = rt_yield_budget - 1
							if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
							loc_2182_ = rt_load_i32_from_u8(loc_2177_, loc_2184_, 0);
							if not (rt_not_equal_i32(rt_and_i32(loc_2182_, 32), 0)) then
								loc_2181_ = loc_2179_;
								loc_2179_ = loc_2181_;
								loc_2182_ = loc_2175_;
								loc_2182_ = loc_2181_[1](loc_2178_, 256, loc_2184_, loc_2182_)
							end
							loc_2182_ = bit32_or(loc_2183_ + -256, 0);
							loc_2183_ = loc_2182_;
						until not (rt_greater_than_u32(loc_2182_, 255))
					end
					loc_2182_ = rt_load_i32_from_u8(loc_2177_, loc_2184_, 0);
					if not (rt_not_equal_i32(rt_and_i32(loc_2182_, 32), 0)) then
						loc_2181_ = loc_2179_;
						loc_2179_ = loc_2181_;
						loc_2182_ = loc_2175_;
						loc_2184_ = loc_2181_[1](loc_2178_, loc_2183_, loc_2184_, loc_2182_)
					end
				end
			end
			loc_2176_[1] = bit32_or(loc_2178_ + 256, 0);
			return loc_2175_
		end), "i32,i32,i32,i32,i32->")
	end)(module_locals[122], module_locals[164], module_locals[3]);
	module_locals[154][1] = (function(loc_2186_, loc_2187_)
		return rt_function_type(--[[fn:long_double_not_supported]](function(loc_2188_)
			local loc_2189_, loc_2190_
			loc_2190_ = loc_2188_;
			loc_2189_ = loc_2186_[1](2157, 10800, loc_2190_)
			loc_2187_[1](loc_2190_)
			loc_2190_ = error('unreachable code');
			return loc_2189_
		end), "->")
	end)(module_locals[124], module_locals[149]);
	module_locals[155] = { nil };
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[155][1] = (function(loc_2191_, loc_2192_)
		return rt_function_type(--[[fn:sbrk]](function(loc_2193_, loc_2194_)
			local loc_2195_, loc_2196_, loc_2197_, loc_2198_, loc_2199_
			if rt_not_equal_i32(loc_2193_, 0) then
				loc_2195_ = loc_2194_;
				loc_2196_ = loc_2193_;
				loc_2197_ = loc_2192_;
				loc_2198_ = loc_2191_;
				if rt_not_equal_i32(rt_and_i32(loc_2196_, 65535), 0) then
					loc_2199_ = 0;
				else
					if rt_less_than_equal_s32(loc_2196_, -1) then
						loc_2199_ = 0;
					else
						loc_2199_ = rt_shift_right_u32(loc_2196_, 16);
						if rt_less_than_equal_u32(loc_2199_, 65535) then
							loc_2196_ = rt_memory_grow(loc_2197_, rt_multiply_i32(loc_2199_, 65536));
							if not (rt_equal_i32(loc_2196_, -1)) then
								loc_2199_ = rt_divide_u32(loc_2196_, 65536);
								loc_2196_ = loc_2199_;
							end
						else
							loc_2196_ = -1;
						end
						if rt_not_equal_i32(loc_2196_, -1) then
							loc_2199_ = 1;
							loc_2196_ = rt_shift_left_i32(loc_2196_, 16);
						else
							loc_2199_ = loc_2196_;
							rt_store_i32(loc_2197_, 0, 27520, 48)
							loc_2199_ = 1;
							loc_2196_ = -1;
						end
					end
				end
				if not (rt_not_equal_i32(loc_2199_, 0)) then
					loc_2199_ = loc_2195_;
					loc_2195_ = loc_2198_;
					loc_2198_ = loc_2195_;
					loc_2195_[1](loc_2199_)
					loc_2199_ = error('unreachable code');
				end
			else
				loc_2195_ = loc_2194_;
				loc_2197_ = loc_2192_;
				loc_2198_ = loc_2191_;
				loc_2199_ = loc_2193_;
				loc_2199_ = rt_memory_size(loc_2197_);
				loc_2199_ = rt_divide_u32(loc_2199_, 65536);
				loc_2196_ = rt_shift_left_i32(loc_2199_, 16);
			end
			return loc_2196_, loc_2195_
		end), "i32->i32")
	end)(module_locals[149], module_locals[3]);
	module_locals[157] = { nil };
	module_locals[156][1] = (function(loc_2200_)
		return rt_function_type(--[[fn:malloc]](function(loc_2201_, loc_2202_)
			local loc_2203_, loc_2204_
			loc_2204_ = loc_2202_;
			loc_2204_ = loc_2200_[1](loc_2201_, loc_2204_)
			return loc_2204_, loc_2203_
		end), "i32->i32")
	end)(module_locals[157]);
	module_locals[158] = { nil };
	end)() end --[[/spider:chunk]]
	module_locals[157][1] = (function(loc_2205_, loc_2206_, loc_2207_, loc_2208_)
		return rt_function_type(--[[fn:dlmalloc]](function(loc_2209_, loc_2210_)
			local loc_2211_, loc_2212_, loc_2213_, loc_2214_, loc_2215_, loc_2216_, loc_2217_, loc_2218_, loc_2219_, loc_2220_, loc_2221_, loc_2222_, loc_2223_, loc_2224_, loc_2225_, loc_2226_, loc_2227_, loc_2228_, loc_2229_, loc_2230_
			loc_2230_ = loc_2207_[1];
			loc_2213_ = loc_2207_;
			loc_2219_ = bit32_or(loc_2230_ - 16, 0);
			loc_2213_[1] = loc_2219_;
			loc_2220_ = buffer_read_i32(loc_2208_[1], 0, 28660);
			loc_2214_ = loc_2208_;
			loc_2217_ = 0;
			loc_2218_ = 0;
			loc_2221_ = 0;
			loc_2222_ = 0;
			loc_2223_ = 0;
			loc_2224_ = 0;
			loc_2225_ = 0;
			if rt_not_equal_i32(loc_2220_, 0) then
				loc_2211_ = loc_2210_;
				loc_2212_ = loc_2209_;
				loc_2215_ = loc_2205_;
				loc_2216_ = loc_2206_;
				loc_2230_ = 0;
			else
				loc_2211_ = loc_2210_;
				loc_2212_ = loc_2209_;
				loc_2215_ = loc_2205_;
				loc_2216_ = loc_2206_;
				loc_2230_ = buffer_read_i32(loc_2214_[1], 0, 29108);
				if not (rt_not_equal_i32(loc_2230_, 0)) then
					rt_store_i64(loc_2214_, 0, 29120, into_bits_i64(4294967295, 4294967295))
					rt_store_i64(loc_2214_, 0, 29112, into_bits_i64(65536, 65536))
					loc_2230_ = rt_exclusive_or_i32(rt_and_i32(bit32_or(loc_2219_ + 8, 0), -16), 1431655768);
					rt_store_i32(loc_2214_, 0, 29108, loc_2230_)
					rt_store_i32(loc_2214_, 0, 29128, 0)
					rt_store_i32(loc_2214_, 0, 29080, 0)
				end
				if rt_less_than_u32(1114112, 1077712) then
					loc_2230_ = 1;
					loc_2229_ = error('unreachable code');
				else
					loc_2229_ = loc_2220_;
					loc_2220_ = 0;
					if rt_less_than_u32(bit32_or(1114112 - 1077712, 0), 89) then
						loc_2230_ = 0;
					else
						loc_2228_ = loc_2221_;
						loc_2229_ = loc_2220_;
						rt_store_i32(loc_2214_, 0, 29084, 1077712)
						rt_store_i32(loc_2214_, 0, 28652, 1077712)
						rt_store_i32(loc_2214_, 0, 28672, loc_2230_)
						rt_store_i32(loc_2214_, 0, 28668, -1)
						loc_2230_ = bit32_or(1114112 - 1077712, 0);
						rt_store_i32(loc_2214_, 0, 29088, loc_2230_)
						rt_store_i32(loc_2214_, 0, 29072, loc_2230_)
						rt_store_i32(loc_2214_, 0, 29068, loc_2230_)
						loc_2230_ = 0;
						repeat
							rt_yield_budget = rt_yield_budget - 1
							if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
							loc_2229_ = bit32_or(loc_2230_ + 28684, 0);
							rt_store_i32(loc_2214_, bit32_or(loc_2230_ + 28696, 0), 0, loc_2229_)
							loc_2228_ = bit32_or(loc_2230_ + 28676, 0);
							rt_store_i32(loc_2214_, loc_2229_, 0, loc_2228_)
							rt_store_i32(loc_2214_, bit32_or(loc_2230_ + 28688, 0), 0, loc_2228_)
							loc_2228_ = bit32_or(loc_2230_ + 28692, 0);
							rt_store_i32(loc_2214_, bit32_or(loc_2230_ + 28704, 0), 0, loc_2228_)
							rt_store_i32(loc_2214_, loc_2228_, 0, loc_2229_)
							loc_2229_ = bit32_or(loc_2230_ + 28700, 0);
							rt_store_i32(loc_2214_, bit32_or(loc_2230_ + 28712, 0), 0, loc_2229_)
							rt_store_i32(loc_2214_, loc_2229_, 0, loc_2228_)
							rt_store_i32(loc_2214_, bit32_or(loc_2230_ + 28708, 0), 0, loc_2229_)
							loc_2229_ = bit32_or(loc_2230_ + 32, 0);
							loc_2230_ = loc_2229_;
						until not (rt_not_equal_i32(loc_2229_, 256))
						rt_store_i32(loc_2214_, bit32_or(1114112 + -52, 0), 0, 56)
						loc_2230_ = buffer_read_i32(loc_2214_[1], 0, 29124);
						rt_store_i32(loc_2214_, 0, 28664, loc_2230_)
						loc_2230_ = rt_and_i32(bit32_or(-8 - 1077712, 0), 15);
						loc_2220_ = bit32_or(1077712 + loc_2230_, 0);
						rt_store_i32(loc_2214_, 0, 28660, loc_2220_)
						loc_2221_ = bit32_or(bit32_or(bit32_or(1114112 - 1077712, 0) - loc_2230_, 0) + -56, 0);
						rt_store_i32(loc_2214_, 0, 28648, loc_2221_)
						rt_store_i32(loc_2214_, loc_2220_, 4, rt_or_i32(loc_2221_, 1))
						loc_2230_ = 0;
					end
				end
			end
			if not (rt_not_equal_i32(loc_2230_, 0)) then
				if rt_greater_than_u32(loc_2212_, 236) then
					loc_2226_ = loc_2223_;
					loc_2223_ = loc_2218_;
					loc_2227_ = loc_2222_;
					loc_2222_ = loc_2220_;
					loc_2228_ = loc_2212_;
					loc_2212_ = loc_2221_;
					loc_2221_ = loc_2225_;
					loc_2225_ = loc_2219_;
					loc_2229_ = loc_2224_;
					loc_2224_ = loc_2217_;
					loc_2221_ = -1;
					if rt_greater_than_u32(loc_2228_, -65) then
						loc_2228_ = 0;
					else
						loc_2229_ = loc_2212_;
						loc_2220_ = buffer_read_i32(loc_2214_[1], 0, 28640);
						loc_2212_ = bit32_or(loc_2228_ + 19, 0);
						loc_2221_ = rt_and_i32(loc_2212_, -16);
						if rt_equal_i32(loc_2220_, 0) then
							loc_2228_ = 0;
						else
							loc_2229_ = 31;
							if rt_greater_than_u32(loc_2228_, 16777196) then
								loc_2219_ = loc_2220_;
								loc_2220_ = loc_2221_;
								loc_2228_ = loc_2212_;
							else
								loc_2219_ = loc_2220_;
								loc_2228_ = loc_2221_;
								loc_2221_ = loc_2229_;
								loc_2229_ = loc_2212_;
								loc_2220_ = loc_2228_;
								loc_2229_ = rt_leading_zeroes_i32(rt_shift_right_u32(loc_2229_, 8));
								loc_2229_ = bit32_or(bit32_or(rt_and_i32(rt_shift_right_u32(loc_2228_, bit32_or(38 - loc_2229_, 0)), 1) - rt_shift_left_i32(loc_2229_, 1), 0) + 62, 0);
							end
							loc_2218_ = buffer_read_i32(loc_2214_[1], rt_shift_left_i32(loc_2229_, 2), 28940);
							loc_2228_ = bit32_or(0 - loc_2220_, 0);
							if rt_not_equal_i32(loc_2218_, 0) then
								loc_2212_ = 0;
								loc_2226_ = 0;
								loc_2217_ = bit32_or(25 - rt_shift_right_u32(loc_2229_, 1), 0);
								if rt_equal_i32(loc_2229_, 31) then
									loc_2221_ = loc_2220_;
								else
									loc_2221_ = loc_2220_;
									loc_2226_ = loc_2217_;
								end
								loc_2226_ = rt_shift_left_i32(loc_2220_, loc_2226_);
								loc_2220_ = 0;
								repeat
									rt_yield_budget = rt_yield_budget - 1
									if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
									loc_2227_ = buffer_read_i32(loc_2214_[1], loc_2218_, 4);
									loc_2227_ = bit32_or(rt_and_i32(loc_2227_, -8) - loc_2221_, 0);
									if rt_greater_than_equal_u32(loc_2227_, loc_2228_) then
										loc_2217_ = loc_2224_;
										loc_2224_ = 0;
									else
										loc_2217_ = loc_2224_;
										loc_2224_ = loc_2220_;
										if rt_not_equal_i32(loc_2227_, 0) then
											loc_2220_ = loc_2218_;
											loc_2228_ = loc_2227_;
											loc_2224_ = 0;
										else
											loc_2220_ = loc_2218_;
											loc_2224_ = loc_2217_;
											loc_2228_ = loc_2227_;
											loc_2224_ = 1;
											loc_2217_ = 0;
											loc_2223_ = 0;
										end
									end
									if not (rt_not_equal_i32(loc_2224_, 0)) then
										loc_2224_ = loc_2223_;
										loc_2223_ = loc_2227_;
										loc_2227_ = loc_2217_;
										loc_2223_ = buffer_read_i32(loc_2214_[1], loc_2218_, 20);
										loc_2218_ = buffer_read_i32(loc_2214_[1], bit32_or(loc_2218_ + rt_and_i32(rt_shift_right_u32(loc_2226_, 29), 4), 0), 16);
										if rt_equal_i32(loc_2223_, loc_2218_) then
											loc_2224_ = loc_2212_;
											loc_2227_ = loc_2223_;
										else
											loc_2217_ = loc_2212_;
											loc_2224_ = loc_2212_;
											loc_2227_ = loc_2223_;
											loc_2212_ = loc_2223_;
										end
										if not (rt_not_equal_i32(loc_2227_, 0)) then
											loc_2223_ = loc_2212_;
											loc_2212_ = loc_2224_;
										end
										loc_2226_ = rt_shift_left_i32(loc_2226_, 1);
										if rt_not_equal_i32(loc_2218_, 0) then
											loc_2217_ = 1;
											loc_2223_ = 65535;
										else
											loc_2217_ = 0;
											loc_2223_ = 1;
										end
									end
									loc_2224_ = loc_2217_;
								until loc_2217_ == 0
								if rt_not_equal_i32(loc_2223_, 0) then
									loc_2218_ = 0;
								else
									loc_2217_ = loc_2220_;
									loc_2220_ = loc_2218_;
									loc_2218_ = loc_2212_;
									loc_2218_ = 1;
									loc_2228_ = 0;
									loc_2212_ = loc_2220_;
								end
							else
								loc_2221_ = loc_2218_;
								loc_2218_ = 0;
								loc_2212_ = 0;
								loc_2221_ = loc_2220_;
								loc_2220_ = 0;
							end
							if rt_not_equal_i32(loc_2218_, 0) then
								loc_2229_ = 0;
							else
								if rt_not_equal_i32(rt_or_i32(loc_2212_, loc_2220_), 0) then
									loc_2229_ = 0;
								else
									loc_2218_ = loc_2220_;
									loc_2220_ = loc_2212_;
									loc_2229_ = rt_shift_left_i32(2, loc_2229_);
									loc_2212_ = rt_and_i32(rt_or_i32(loc_2229_, bit32_or(0 - loc_2229_, 0)), loc_2219_);
									loc_2220_ = 0;
									if rt_equal_i32(loc_2212_, 0) then
										loc_2229_ = 1;
									else
										loc_2212_ = buffer_read_i32(loc_2214_[1], rt_shift_left_i32(rt_trailing_zeroes_i32(loc_2212_), 2), 28940);
										loc_2229_ = 0;
									end
								end
								if rt_not_equal_i32(loc_2229_, 0) then
									loc_2229_ = 2;
								else
									if rt_equal_i32(loc_2212_, 0) then
										loc_2229_ = 1;
									else
										loc_2229_ = 0;
									end
								end
							end
							if (loc_2229_) >= 0 and (loc_2229_) < 2 then
								if (loc_2229_) < 1 then
									repeat
										rt_yield_budget = rt_yield_budget - 1
										if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
										loc_2229_ = loc_2227_;
										loc_2227_ = loc_2226_;
										loc_2227_ = buffer_read_i32(loc_2214_[1], loc_2212_, 4);
										loc_2229_ = buffer_read_i32(loc_2214_[1], loc_2212_, 16);
										loc_2227_ = bit32_or(rt_and_i32(loc_2227_, -8) - loc_2221_, 0);
										loc_2226_ = (rt_less_than_u32(loc_2227_, loc_2228_) and 1 or 0);
										if rt_not_equal_i32(loc_2229_, 0) then
											loc_2217_ = loc_2228_;
											loc_2218_ = loc_2220_;
											loc_2220_ = loc_2212_;
											loc_2228_ = loc_2227_;
										else
											loc_2217_ = loc_2228_;
											loc_2218_ = loc_2220_;
											loc_2220_ = loc_2212_;
											loc_2228_ = loc_2227_;
											loc_2229_ = buffer_read_i32(loc_2214_[1], loc_2220_, 20);
										end
										if rt_not_equal_i32(loc_2226_, 0) then
											loc_2227_ = loc_2228_;
										else
											loc_2227_ = loc_2228_;
											loc_2228_ = loc_2217_;
										end
										if not (rt_not_equal_i32(loc_2226_, 0)) then
											loc_2220_ = loc_2218_;
										end
										loc_2212_ = loc_2229_;
									until loc_2229_ == 0
									loc_2229_ = 0;
								else
									loc_2229_ = 0;
								end
							else
								loc_2229_ = 1;
							end
							if rt_not_equal_i32(loc_2229_, 0) then
								loc_2228_ = 0;
							else
								if rt_equal_i32(loc_2220_, 0) then
									loc_2228_ = 0;
								else
									loc_2229_ = buffer_read_i32(loc_2214_[1], 0, 28644);
									if rt_greater_than_equal_u32(loc_2228_, bit32_or(loc_2229_ - loc_2221_, 0)) then
										loc_2228_ = 0;
									else
										loc_2218_ = loc_2226_;
										loc_2229_ = loc_2212_;
										loc_2229_ = buffer_read_i32(loc_2214_[1], loc_2220_, 24);
										loc_2226_ = buffer_read_i32(loc_2214_[1], loc_2220_, 12);
										if rt_equal_i32(loc_2226_, loc_2220_) then
											loc_2217_ = loc_2228_;
											loc_2228_ = loc_2227_;
											loc_2227_ = loc_2220_;
											loc_2220_ = loc_2229_;
											loc_2218_, loc_2219_ = loc_2219_, loc_2218_;
											loc_2229_ = buffer_read_i32(loc_2214_[1], loc_2227_, 20);
											if rt_equal_i32(loc_2229_, 0) then
												loc_2229_ = buffer_read_i32(loc_2214_[1], loc_2227_, 16);
												if rt_equal_i32(loc_2229_, 0) then
													loc_2212_ = 1;
													loc_2226_ = 0;
												else
													loc_2212_ = 0;
													loc_2219_ = bit32_or(loc_2227_ + 16, 0);
												end
											else
												loc_2212_ = 0;
												loc_2219_ = bit32_or(loc_2227_ + 20, 0);
											end
											if not (rt_not_equal_i32(loc_2212_, 0)) then
												repeat
													rt_yield_budget = rt_yield_budget - 1
													if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
													loc_2224_, loc_2228_ = loc_2228_, loc_2224_;
													loc_2228_, loc_2226_ = loc_2226_, loc_2228_;
													loc_2226_, loc_2229_ = loc_2229_, loc_2226_;
													loc_2229_ = buffer_read_i32(loc_2214_[1], loc_2226_, 20);
													loc_2228_ = bit32_or(loc_2226_ + 20, 0);
													if rt_not_equal_i32(loc_2229_, 0) then
														loc_2224_ = loc_2223_;
														loc_2219_, loc_2228_ = loc_2228_, loc_2219_;
														loc_2212_ = 1;
														loc_2223_ = 65535;
													else
														loc_2224_ = loc_2223_;
														loc_2223_ = loc_2228_;
														loc_2228_ = loc_2219_;
														loc_2229_ = buffer_read_i32(loc_2214_[1], loc_2226_, 16);
														loc_2219_ = bit32_or(loc_2226_ + 16, 0);
														if rt_not_equal_i32(loc_2229_, 0) then
															loc_2212_ = 1;
															loc_2223_ = 65535;
														else
															loc_2212_ = 0;
															loc_2223_ = loc_2224_;
														end
													end
													loc_2224_ = loc_2212_;
												until loc_2212_ == 0
												rt_store_i32(loc_2214_, loc_2228_, 0, 0)
											end
										else
											loc_2217_ = loc_2228_;
											loc_2228_ = loc_2227_;
											loc_2227_ = loc_2220_;
											loc_2220_ = loc_2229_;
											loc_2229_ = loc_2218_;
											loc_2218_ = loc_2219_;
											loc_2229_ = buffer_read_i32(loc_2214_[1], loc_2227_, 8);
											rt_store_i32(loc_2214_, loc_2229_, 12, loc_2226_)
											rt_store_i32(loc_2214_, loc_2226_, 8, loc_2229_)
										end
										if not (rt_equal_i32(loc_2220_, 0)) then
											loc_2212_ = buffer_read_i32(loc_2214_[1], loc_2227_, 28);
											loc_2219_ = rt_shift_left_i32(loc_2212_, 2);
											loc_2229_ = buffer_read_i32(loc_2214_[1], loc_2219_, 28940);
											if rt_not_equal_i32(loc_2227_, loc_2229_) then
												loc_2219_ = buffer_read_i32(loc_2214_[1], loc_2220_, 16);
												if rt_not_equal_i32(loc_2219_, loc_2227_) then
													rt_store_i32(loc_2214_, loc_2220_, 20, loc_2226_)
												else
													rt_store_i32(loc_2214_, loc_2220_, 16, loc_2226_)
												end
												if rt_equal_i32(loc_2226_, 0) then
													loc_2219_ = 1;
												else
													loc_2219_ = 0;
												end
											else
												rt_store_i32(loc_2214_, bit32_or(loc_2219_ + 28940, 0), 0, loc_2226_)
												if rt_not_equal_i32(loc_2226_, 0) then
													loc_2219_ = loc_2212_;
													loc_2219_ = 0;
												else
													loc_2219_ = loc_2212_;
													loc_2218_ = rt_and_i32(loc_2218_, rt_rotate_left_i32(-2, loc_2219_));
													rt_store_i32(loc_2214_, 0, 28640, loc_2218_)
													loc_2219_ = 1;
												end
											end
											if not (rt_not_equal_i32(loc_2219_, 0)) then
												loc_2220_, loc_2226_ = loc_2226_, loc_2220_;
												rt_store_i32(loc_2214_, loc_2220_, 24, loc_2226_)
												loc_2226_ = buffer_read_i32(loc_2214_[1], loc_2227_, 16);
												if not (rt_equal_i32(loc_2226_, 0)) then
													rt_store_i32(loc_2214_, loc_2220_, 16, loc_2226_)
													rt_store_i32(loc_2214_, loc_2226_, 24, loc_2220_)
												end
												loc_2226_ = buffer_read_i32(loc_2214_[1], loc_2227_, 20);
												if not (rt_equal_i32(loc_2226_, 0)) then
													rt_store_i32(loc_2214_, loc_2220_, 20, loc_2226_)
													rt_store_i32(loc_2214_, loc_2226_, 24, loc_2220_)
												end
											end
										end
										if rt_greater_than_u32(loc_2217_, 15) then
											loc_2226_ = bit32_or(loc_2227_ + loc_2221_, 0);
											rt_store_i32(loc_2214_, loc_2226_, 4, rt_or_i32(loc_2217_, 1))
											rt_store_i32(loc_2214_, loc_2227_, 4, rt_or_i32(loc_2221_, 3))
											rt_store_i32(loc_2214_, bit32_or(loc_2226_ + loc_2217_, 0), 0, loc_2217_)
											if rt_greater_than_u32(loc_2217_, 255) then
												loc_2219_ = 31;
												if not (rt_greater_than_u32(loc_2217_, 16777215)) then
													loc_2220_ = loc_2217_;
													loc_2221_ = loc_2219_;
													loc_2217_ = loc_2220_;
													loc_2221_ = rt_leading_zeroes_i32(rt_shift_right_u32(loc_2220_, 8));
													loc_2219_ = bit32_or(bit32_or(rt_and_i32(rt_shift_right_u32(loc_2220_, bit32_or(38 - loc_2221_, 0)), 1) - rt_shift_left_i32(loc_2221_, 1), 0) + 62, 0);
												end
												rt_store_i32(loc_2214_, loc_2226_, 28, loc_2219_)
												rt_store_i64(loc_2214_, loc_2226_, 16, into_bits_i64(0, 0))
												loc_2220_ = rt_shift_left_i32(1, loc_2219_);
												loc_2221_ = bit32_or(rt_shift_left_i32(loc_2219_, 2) + 28940, 0);
												if rt_not_equal_i32(rt_and_i32(loc_2218_, loc_2220_), 0) then
													loc_2218_ = 0;
													loc_2220_ = bit32_or(25 - rt_shift_right_u32(loc_2219_, 1), 0);
													if rt_equal_i32(loc_2219_, 31) then
														loc_2219_ = loc_2217_;
													else
														loc_2219_ = loc_2217_;
														loc_2218_ = loc_2220_;
													end
													loc_2220_ = buffer_read_i32(loc_2214_[1], loc_2221_, 0);
													loc_2218_ = rt_shift_left_i32(loc_2217_, loc_2218_);
													repeat
														rt_yield_budget = rt_yield_budget - 1
														if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
														loc_2224_ = buffer_read_i32(loc_2214_[1], loc_2220_, 4);
														if rt_equal_i32(rt_and_i32(loc_2224_, -8), loc_2219_) then
															loc_2221_ = loc_2220_;
															loc_2217_ = 0;
															loc_2223_ = 1;
														else
															loc_2221_ = loc_2220_;
															loc_2224_ = loc_2228_;
															loc_2228_ = loc_2220_;
															loc_2228_ = bit32_or(loc_2221_ + rt_and_i32(rt_shift_right_u32(loc_2218_, 29), 4), 0);
															loc_2220_ = buffer_read_i32(loc_2214_[1], loc_2228_, 16);
															loc_2218_ = rt_shift_left_i32(loc_2218_, 1);
															if rt_not_equal_i32(loc_2220_, 0) then
																loc_2217_ = 1;
																loc_2223_ = 65535;
															else
																loc_2217_ = 0;
																loc_2223_ = 0;
															end
														end
														loc_2224_ = loc_2217_;
													until loc_2217_ == 0
													if rt_not_equal_i32(loc_2223_, 0) then
														loc_2228_ = buffer_read_i32(loc_2214_[1], loc_2221_, 8);
														rt_store_i32(loc_2214_, loc_2228_, 12, loc_2226_)
														rt_store_i32(loc_2214_, loc_2221_, 8, loc_2226_)
														rt_store_i32(loc_2214_, loc_2226_, 24, 0)
														rt_store_i32(loc_2214_, loc_2226_, 12, loc_2221_)
														rt_store_i32(loc_2214_, loc_2226_, 8, loc_2228_)
													else
														rt_store_i32(loc_2214_, bit32_or(loc_2228_ + 16, 0), 0, loc_2226_)
														rt_store_i32(loc_2214_, loc_2226_, 24, loc_2221_)
														rt_store_i32(loc_2214_, loc_2226_, 12, loc_2226_)
														rt_store_i32(loc_2214_, loc_2226_, 8, loc_2226_)
													end
												else
													loc_2217_, loc_2228_ = loc_2228_, loc_2217_;
													rt_store_i32(loc_2214_, loc_2221_, 0, loc_2226_)
													rt_store_i32(loc_2214_, 0, 28640, rt_or_i32(loc_2218_, loc_2220_))
													rt_store_i32(loc_2214_, loc_2226_, 24, loc_2221_)
													rt_store_i32(loc_2214_, loc_2226_, 8, loc_2226_)
													rt_store_i32(loc_2214_, loc_2226_, 12, loc_2226_)
												end
											else
												loc_2221_ = loc_2218_;
												loc_2226_, loc_2228_ = loc_2228_, loc_2226_;
												loc_2221_ = buffer_read_i32(loc_2214_[1], 0, 28636);
												loc_2226_ = rt_shift_left_i32(1, rt_shift_right_u32(loc_2217_, 3));
												loc_2220_ = bit32_or(rt_and_i32(loc_2217_, -8) + 28676, 0);
												if rt_not_equal_i32(rt_and_i32(loc_2221_, loc_2226_), 0) then
													loc_2226_ = buffer_read_i32(loc_2214_[1], loc_2220_, 8);
												else
													rt_store_i32(loc_2214_, 0, 28636, rt_or_i32(loc_2221_, loc_2226_))
													loc_2226_ = loc_2220_;
												end
												rt_store_i32(loc_2214_, loc_2226_, 12, loc_2228_)
												rt_store_i32(loc_2214_, loc_2220_, 8, loc_2228_)
												rt_store_i32(loc_2214_, loc_2228_, 12, loc_2220_)
												rt_store_i32(loc_2214_, loc_2228_, 8, loc_2226_)
											end
										else
											loc_2226_ = loc_2218_;
											loc_2228_ = rt_or_i32(loc_2217_, loc_2221_);
											rt_store_i32(loc_2214_, loc_2227_, 4, rt_or_i32(loc_2228_, 3))
											loc_2226_ = bit32_or(loc_2227_ + loc_2228_, 0);
											loc_2228_ = buffer_read_i32(loc_2214_[1], loc_2226_, 4);
											rt_store_i32(loc_2214_, loc_2226_, 4, rt_or_i32(loc_2228_, 1))
										end
										loc_2228_ = 1;
										loc_2212_ = bit32_or(loc_2227_ + 8, 0);
									end
								end
							end
						end
					end
				else
					loc_2226_ = loc_2223_;
					loc_2223_ = loc_2218_;
					loc_2227_ = loc_2222_;
					loc_2222_ = loc_2220_;
					loc_2228_ = loc_2212_;
					loc_2229_ = loc_2224_;
					loc_2224_ = loc_2217_;
					loc_2230_ = loc_2221_;
					loc_2221_ = loc_2225_;
					loc_2225_ = loc_2219_;
					loc_2230_ = buffer_read_i32(loc_2214_[1], 0, 28636);
					loc_2226_ = 16;
					loc_2227_ = rt_and_i32(bit32_or(loc_2228_ + 19, 0), 496);
					if rt_less_than_u32(loc_2228_, 11) then
						loc_2220_ = loc_2221_;
						loc_2221_ = loc_2226_;
						loc_2226_ = loc_2229_;
						loc_2228_ = loc_2230_;
						loc_2229_ = loc_2227_;
					else
						loc_2220_ = loc_2221_;
						loc_2228_ = loc_2230_;
						loc_2226_, loc_2229_ = loc_2229_, loc_2226_;
						loc_2229_, loc_2227_ = loc_2227_, loc_2229_;
						loc_2221_ = loc_2229_;
					end
					loc_2229_ = rt_shift_right_u32(loc_2221_, 3);
					loc_2212_ = rt_shift_right_u32(loc_2230_, loc_2229_);
					if rt_equal_i32(rt_and_i32(loc_2212_, 3), 0) then
						loc_2227_ = buffer_read_i32(loc_2214_[1], 0, 28644);
						if rt_less_than_equal_u32(loc_2221_, loc_2227_) then
							loc_2228_ = 0;
						else
							if rt_equal_i32(loc_2212_, 0) then
								loc_2230_ = loc_2229_;
								loc_2229_ = loc_2228_;
								loc_2228_ = loc_2227_;
								loc_2227_ = loc_2226_;
								loc_2226_ = buffer_read_i32(loc_2214_[1], 0, 28640);
								if rt_equal_i32(loc_2226_, 0) then
									loc_2228_ = 0;
								else
									loc_2219_ = loc_2227_;
									loc_2227_ = loc_2220_;
									loc_2220_ = loc_2228_;
									loc_2230_ = loc_2222_;
									loc_2222_ = loc_2226_;
									loc_2226_ = loc_2229_;
									loc_2229_ = loc_2212_;
									loc_2229_ = buffer_read_i32(loc_2214_[1], rt_shift_left_i32(rt_trailing_zeroes_i32(loc_2222_), 2), 28940);
									loc_2228_ = buffer_read_i32(loc_2214_[1], loc_2229_, 4);
									loc_2230_ = loc_2229_;
									loc_2228_ = bit32_or(rt_and_i32(loc_2228_, -8) - loc_2221_, 0);
									loc_2217_ = loc_2219_;
									loc_2219_ = loc_2222_;
									loc_2212_ = loc_2227_;
									repeat
										rt_yield_budget = rt_yield_budget - 1
										if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
										loc_2227_ = buffer_read_i32(loc_2214_[1], loc_2230_, 16);
										if rt_not_equal_i32(loc_2227_, 0) then
											loc_2224_, loc_2227_ = loc_2227_, loc_2224_;
											loc_2222_ = 0;
										else
											loc_2224_, loc_2227_ = loc_2227_, loc_2224_;
											loc_2224_ = buffer_read_i32(loc_2214_[1], loc_2230_, 20);
											if rt_equal_i32(loc_2224_, 0) then
												loc_2222_ = 1;
												loc_2227_ = 0;
											else
												loc_2222_ = 0;
											end
										end
										if not (rt_not_equal_i32(loc_2222_, 0)) then
											loc_2223_, loc_2230_ = loc_2230_, loc_2223_;
											loc_2230_, loc_2227_ = loc_2227_, loc_2230_;
											loc_2227_, loc_2228_ = loc_2228_, loc_2227_;
											loc_2230_ = buffer_read_i32(loc_2214_[1], loc_2224_, 4);
											loc_2228_ = bit32_or(rt_and_i32(loc_2230_, -8) - loc_2221_, 0);
											loc_2230_ = (rt_less_than_u32(loc_2228_, loc_2227_) and 1 or 0);
											if rt_not_equal_i32(loc_2230_, 0) then
												loc_2224_, loc_2227_ = loc_2227_, loc_2224_;
												loc_2227_, loc_2229_ = loc_2229_, loc_2227_;
											else
												loc_2224_, loc_2227_ = loc_2227_, loc_2224_;
												loc_2227_, loc_2229_ = loc_2229_, loc_2227_;
												loc_2228_ = loc_2224_;
											end
											if rt_not_equal_i32(loc_2230_, 0) then
												loc_2230_ = loc_2229_;
											else
												loc_2230_ = loc_2229_;
												loc_2229_ = loc_2227_;
											end
											loc_2227_ = 1;
											loc_2223_ = 65535;
										end
										loc_2224_ = loc_2227_;
									until loc_2227_ == 0
									loc_2222_ = buffer_read_i32(loc_2214_[1], loc_2229_, 24);
									loc_2230_ = buffer_read_i32(loc_2214_[1], loc_2229_, 12);
									if rt_equal_i32(loc_2230_, loc_2229_) then
										loc_2227_ = buffer_read_i32(loc_2214_[1], loc_2229_, 20);
										if rt_equal_i32(loc_2227_, 0) then
											loc_2218_ = buffer_read_i32(loc_2214_[1], loc_2229_, 16);
											if rt_equal_i32(loc_2218_, 0) then
												loc_2230_ = 1;
												loc_2227_ = 0;
											else
												loc_2217_, loc_2229_ = loc_2229_, loc_2217_;
												loc_2229_, loc_2230_ = loc_2230_, loc_2229_;
												loc_2230_ = 0;
												loc_2227_ = loc_2229_;
												loc_2229_ = loc_2217_;
												loc_2217_ = bit32_or(loc_2217_ + 16, 0);
											end
										else
											loc_2217_, loc_2229_ = loc_2229_, loc_2217_;
											loc_2229_, loc_2230_ = loc_2230_, loc_2229_;
											loc_2230_ = 0;
											loc_2218_ = loc_2227_;
											loc_2227_ = loc_2229_;
											loc_2229_ = loc_2217_;
											loc_2217_ = bit32_or(loc_2217_ + 20, 0);
										end
										if not (rt_not_equal_i32(loc_2230_, 0)) then
											loc_2230_ = loc_2212_;
											loc_2217_, loc_2218_ = loc_2218_, loc_2217_;
											loc_2212_ = loc_2218_;
											loc_2218_ = loc_2230_;
											repeat
												rt_yield_budget = rt_yield_budget - 1
												if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
												loc_2230_ = loc_2212_;
												loc_2217_, loc_2218_ = loc_2218_, loc_2217_;
												loc_2218_, loc_2227_ = loc_2227_, loc_2218_;
												loc_2217_ = buffer_read_i32(loc_2214_[1], loc_2227_, 20);
												loc_2212_ = bit32_or(loc_2227_ + 20, 0);
												if rt_not_equal_i32(loc_2217_, 0) then
													loc_2218_ = loc_2230_;
													loc_2230_ = loc_2223_;
													loc_2230_ = 1;
													loc_2223_ = 65535;
												else
													loc_2218_ = loc_2230_;
													loc_2224_ = loc_2217_;
													loc_2230_ = loc_2223_;
													loc_2223_ = loc_2212_;
													loc_2217_ = buffer_read_i32(loc_2214_[1], loc_2227_, 16);
													loc_2212_ = bit32_or(loc_2227_ + 16, 0);
													if rt_not_equal_i32(loc_2217_, 0) then
														loc_2230_ = 1;
														loc_2223_ = 65535;
													else
														loc_2224_ = loc_2230_;
														loc_2230_ = 0;
														loc_2223_ = loc_2224_;
													end
												end
												loc_2224_ = loc_2230_;
											until loc_2230_ == 0
											rt_store_i32(loc_2214_, loc_2218_, 0, 0)
										end
									else
										loc_2218_ = loc_2212_;
										loc_2227_ = loc_2217_;
										loc_2227_ = buffer_read_i32(loc_2214_[1], loc_2229_, 8);
										rt_store_i32(loc_2214_, loc_2227_, 12, loc_2230_)
										rt_store_i32(loc_2214_, loc_2230_, 8, loc_2227_)
										loc_2227_ = loc_2230_;
									end
									if not (rt_equal_i32(loc_2222_, 0)) then
										loc_2212_ = loc_2219_;
										loc_2218_ = buffer_read_i32(loc_2214_[1], loc_2229_, 28);
										loc_2219_ = rt_shift_left_i32(loc_2218_, 2);
										loc_2217_ = buffer_read_i32(loc_2214_[1], loc_2219_, 28940);
										if rt_not_equal_i32(loc_2229_, loc_2217_) then
											loc_2217_ = loc_2212_;
											loc_2219_ = buffer_read_i32(loc_2214_[1], loc_2222_, 16);
											if rt_not_equal_i32(loc_2219_, loc_2229_) then
												rt_store_i32(loc_2214_, loc_2222_, 20, loc_2227_)
											else
												rt_store_i32(loc_2214_, loc_2222_, 16, loc_2227_)
											end
											if rt_equal_i32(loc_2227_, 0) then
												loc_2219_ = 1;
											else
												loc_2219_ = 0;
											end
										else
											loc_2217_ = loc_2212_;
											rt_store_i32(loc_2214_, bit32_or(loc_2219_ + 28940, 0), 0, loc_2227_)
											if rt_not_equal_i32(loc_2227_, 0) then
												loc_2219_ = loc_2218_;
												loc_2218_ = loc_2217_;
												loc_2219_ = 0;
											else
												loc_2219_ = loc_2218_;
												loc_2218_ = loc_2217_;
												rt_store_i32(loc_2214_, 0, 28640, rt_and_i32(loc_2218_, rt_rotate_left_i32(-2, loc_2219_)))
												loc_2219_ = 1;
											end
										end
										if not (rt_not_equal_i32(loc_2219_, 0)) then
											loc_2219_ = loc_2227_;
											rt_store_i32(loc_2214_, loc_2219_, 24, loc_2222_)
											loc_2227_ = buffer_read_i32(loc_2214_[1], loc_2229_, 16);
											if not (rt_equal_i32(loc_2227_, 0)) then
												rt_store_i32(loc_2214_, loc_2219_, 16, loc_2227_)
												rt_store_i32(loc_2214_, loc_2227_, 24, loc_2219_)
											end
											loc_2227_ = buffer_read_i32(loc_2214_[1], loc_2229_, 20);
											if not (rt_equal_i32(loc_2227_, 0)) then
												rt_store_i32(loc_2214_, loc_2219_, 20, loc_2227_)
												rt_store_i32(loc_2214_, loc_2227_, 24, loc_2219_)
											end
										end
									end
									if rt_greater_than_u32(loc_2228_, 15) then
										loc_2227_ = bit32_or(loc_2229_ + loc_2221_, 0);
										rt_store_i32(loc_2214_, loc_2227_, 4, rt_or_i32(loc_2228_, 1))
										rt_store_i32(loc_2214_, loc_2229_, 4, rt_or_i32(loc_2221_, 3))
										rt_store_i32(loc_2214_, bit32_or(loc_2227_ + loc_2228_, 0), 0, loc_2228_)
										if not (rt_equal_i32(loc_2220_, 0)) then
											loc_2219_ = loc_2220_;
											loc_2220_ = buffer_read_i32(loc_2214_[1], 0, 28656);
											loc_2221_ = bit32_or(rt_and_i32(loc_2219_, -8) + 28676, 0);
											loc_2219_ = rt_shift_left_i32(1, rt_shift_right_u32(loc_2219_, 3));
											if rt_not_equal_i32(rt_and_i32(loc_2219_, loc_2226_), 0) then
												loc_2226_ = buffer_read_i32(loc_2214_[1], loc_2221_, 8);
											else
												loc_2221_, loc_2226_ = loc_2226_, loc_2221_;
												rt_store_i32(loc_2214_, 0, 28636, rt_or_i32(loc_2219_, loc_2221_))
												loc_2221_ = loc_2226_;
											end
											rt_store_i32(loc_2214_, loc_2226_, 12, loc_2220_)
											rt_store_i32(loc_2214_, loc_2221_, 8, loc_2220_)
											rt_store_i32(loc_2214_, loc_2220_, 12, loc_2221_)
											rt_store_i32(loc_2214_, loc_2220_, 8, loc_2226_)
										end
										rt_store_i32(loc_2214_, 0, 28656, loc_2227_)
										rt_store_i32(loc_2214_, 0, 28644, loc_2228_)
									else
										loc_2227_ = loc_2226_;
										loc_2226_ = loc_2220_;
										loc_2228_ = rt_or_i32(loc_2228_, loc_2221_);
										rt_store_i32(loc_2214_, loc_2229_, 4, rt_or_i32(loc_2228_, 3))
										loc_2227_ = bit32_or(loc_2229_ + loc_2228_, 0);
										loc_2228_ = buffer_read_i32(loc_2214_[1], loc_2227_, 4);
										rt_store_i32(loc_2214_, loc_2227_, 4, rt_or_i32(loc_2228_, 1))
									end
									loc_2228_ = 1;
									loc_2212_ = bit32_or(loc_2229_ + 8, 0);
								end
							else
								loc_2230_ = loc_2229_;
								loc_2229_ = loc_2226_;
								loc_2226_ = loc_2228_;
								loc_2228_ = loc_2227_;
								loc_2227_ = loc_2220_;
								loc_2229_ = rt_shift_left_i32(2, loc_2230_);
								loc_2229_ = rt_trailing_zeroes_i32(rt_and_i32(rt_shift_left_i32(loc_2212_, loc_2230_), rt_or_i32(loc_2229_, bit32_or(0 - loc_2229_, 0))));
								loc_2220_ = rt_shift_left_i32(loc_2229_, 3);
								loc_2230_ = buffer_read_i32(loc_2214_[1], loc_2220_, 28684);
								loc_2227_ = buffer_read_i32(loc_2214_[1], loc_2230_, 8);
								loc_2220_ = bit32_or(loc_2220_ + 28676, 0);
								if rt_not_equal_i32(loc_2220_, loc_2227_) then
									loc_2226_, loc_2228_ = loc_2228_, loc_2226_;
									loc_2228_, loc_2227_ = loc_2227_, loc_2228_;
									rt_store_i32(loc_2214_, loc_2220_, 8, loc_2228_)
									rt_store_i32(loc_2214_, loc_2228_, 12, loc_2220_)
								else
									loc_2220_, loc_2227_ = loc_2227_, loc_2220_;
									loc_2227_, loc_2226_ = loc_2226_, loc_2227_;
									loc_2226_, loc_2228_ = loc_2228_, loc_2226_;
									loc_2227_ = rt_and_i32(loc_2227_, rt_rotate_left_i32(-2, loc_2229_));
									rt_store_i32(loc_2214_, 0, 28636, loc_2227_)
								end
								rt_store_i32(loc_2214_, loc_2230_, 4, rt_or_i32(loc_2221_, 3))
								loc_2228_ = rt_shift_left_i32(loc_2229_, 3);
								loc_2229_ = bit32_or(loc_2228_ - loc_2221_, 0);
								rt_store_i32(loc_2214_, bit32_or(loc_2230_ + loc_2228_, 0), 0, loc_2229_)
								loc_2228_ = bit32_or(loc_2230_ + loc_2221_, 0);
								rt_store_i32(loc_2214_, loc_2228_, 4, rt_or_i32(loc_2229_, 1))
								if not (rt_equal_i32(loc_2226_, 0)) then
									loc_2220_ = loc_2226_;
									loc_2226_ = loc_2221_;
									loc_2226_ = buffer_read_i32(loc_2214_[1], 0, 28656);
									loc_2221_ = bit32_or(rt_and_i32(loc_2220_, -8) + 28676, 0);
									loc_2220_ = rt_shift_left_i32(1, rt_shift_right_u32(loc_2220_, 3));
									if rt_not_equal_i32(rt_and_i32(loc_2227_, loc_2220_), 0) then
										loc_2227_ = buffer_read_i32(loc_2214_[1], loc_2221_, 8);
									else
										loc_2221_, loc_2227_ = loc_2227_, loc_2221_;
										rt_store_i32(loc_2214_, 0, 28636, rt_or_i32(loc_2221_, loc_2220_))
										loc_2221_ = loc_2227_;
									end
									rt_store_i32(loc_2214_, loc_2227_, 12, loc_2226_)
									rt_store_i32(loc_2214_, loc_2221_, 8, loc_2226_)
									rt_store_i32(loc_2214_, loc_2226_, 12, loc_2221_)
									rt_store_i32(loc_2214_, loc_2226_, 8, loc_2227_)
								end
								rt_store_i32(loc_2214_, 0, 28656, loc_2228_)
								rt_store_i32(loc_2214_, 0, 28644, loc_2229_)
								loc_2228_ = 1;
								loc_2212_ = bit32_or(loc_2230_ + 8, 0);
							end
						end
					else
						loc_2227_ = loc_2220_;
						loc_2230_ = loc_2221_;
						loc_2226_, loc_2228_ = loc_2228_, loc_2226_;
						loc_2229_ = rt_exclusive_or_i32(rt_or_i32(rt_and_i32(loc_2212_, 1), loc_2229_), 1);
						loc_2228_ = rt_shift_left_i32(loc_2229_, 3);
						loc_2230_ = buffer_read_i32(loc_2214_[1], loc_2228_, 28684);
						loc_2227_ = buffer_read_i32(loc_2214_[1], loc_2230_, 8);
						loc_2228_ = bit32_or(loc_2228_ + 28676, 0);
						if rt_not_equal_i32(loc_2228_, loc_2227_) then
							rt_store_i32(loc_2214_, loc_2228_, 8, loc_2227_)
							rt_store_i32(loc_2214_, loc_2227_, 12, loc_2228_)
						else
							loc_2227_, loc_2228_ = loc_2228_, loc_2227_;
							rt_store_i32(loc_2214_, 0, 28636, rt_and_i32(loc_2226_, rt_rotate_left_i32(-2, loc_2229_)))
						end
						loc_2221_ = rt_shift_left_i32(loc_2229_, 3);
						rt_store_i32(loc_2214_, loc_2230_, 4, rt_or_i32(loc_2221_, 3))
						loc_2228_ = bit32_or(loc_2230_ + loc_2221_, 0);
						loc_2229_ = buffer_read_i32(loc_2214_[1], loc_2228_, 4);
						rt_store_i32(loc_2214_, loc_2228_, 4, rt_or_i32(loc_2229_, 1))
						loc_2228_ = 1;
						loc_2212_ = bit32_or(loc_2230_ + 8, 0);
					end
				end
				if not (rt_not_equal_i32(loc_2228_, 0)) then
					loc_2228_ = loc_2212_;
					loc_2228_ = buffer_read_i32(loc_2214_[1], 0, 28644);
					if rt_less_than_u32(loc_2228_, loc_2221_) then
						loc_2220_ = loc_2221_;
						loc_2221_ = loc_2222_;
						loc_2222_ = buffer_read_i32(loc_2214_[1], 0, 28648);
						if rt_less_than_equal_u32(loc_2222_, loc_2220_) then
							loc_2228_ = buffer_read_i32(loc_2214_[1], 0, 29108);
							if rt_equal_i32(loc_2228_, 0) then
								rt_store_i64(loc_2214_, 0, 29120, into_bits_i64(4294967295, 4294967295))
								rt_store_i64(loc_2214_, 0, 29112, into_bits_i64(65536, 65536))
								rt_store_i32(loc_2214_, 0, 29108, rt_exclusive_or_i32(rt_and_i32(bit32_or(loc_2225_ + 12, 0), -16), 1431655768))
								rt_store_i32(loc_2214_, 0, 29128, 0)
								rt_store_i32(loc_2214_, 0, 29080, 0)
								loc_2227_ = 65536;
							else
								loc_2227_ = buffer_read_i32(loc_2214_[1], 0, 29116);
							end
							loc_2228_ = 0;
							loc_2219_ = bit32_or(0 - loc_2227_, 0);
							loc_2226_ = bit32_or(loc_2220_ + 71, 0);
							loc_2218_ = bit32_or(loc_2227_ + loc_2226_, 0);
							loc_2217_ = rt_and_i32(loc_2218_, loc_2219_);
							if rt_greater_than_u32(loc_2217_, loc_2220_) then
								loc_2212_ = buffer_read_i32(loc_2214_[1], 0, 29076);
								if rt_equal_i32(loc_2212_, 0) then
									loc_2228_ = 0;
								else
									loc_2227_ = buffer_read_i32(loc_2214_[1], 0, 29068);
									loc_2228_ = bit32_or(loc_2227_ + loc_2217_, 0);
									if rt_less_than_equal_u32(loc_2228_, loc_2227_) then
										loc_2228_ = 0;
									else
										if rt_less_than_equal_u32(loc_2228_, loc_2212_) then
											loc_2228_ = 1;
										else
											loc_2228_ = 0;
										end
									end
									if rt_not_equal_i32(loc_2228_, 0) then
										loc_2228_ = 0;
									else
										loc_2228_ = loc_2212_;
										rt_store_i32(loc_2214_, 0, 27520, 48)
										loc_2228_ = 1;
										loc_2212_ = 0;
									end
								end
								if not (rt_not_equal_i32(loc_2228_, 0)) then
									loc_2228_ = rt_load_i32_from_u8(loc_2214_, 0, 29080);
									if rt_not_equal_i32(rt_and_i32(loc_2228_, 4), 0) then
										loc_2227_ = loc_2221_;
										loc_2221_ = loc_2219_;
										loc_2219_ = loc_2217_;
										loc_2218_, loc_2226_ = loc_2226_, loc_2218_;
										loc_2226_, loc_2224_ = loc_2224_, loc_2226_;
										loc_2224_, loc_2223_ = loc_2223_, loc_2224_;
										loc_2223_, loc_2222_ = loc_2222_, loc_2223_;
										loc_2222_, loc_2220_ = loc_2220_, loc_2222_;
										loc_2227_ = 0;
									else
										loc_2227_ = loc_2221_;
										loc_2221_ = loc_2219_;
										loc_2219_ = loc_2217_;
										loc_2218_, loc_2226_ = loc_2226_, loc_2218_;
										loc_2226_, loc_2224_ = loc_2224_, loc_2226_;
										loc_2224_, loc_2223_ = loc_2223_, loc_2224_;
										loc_2223_, loc_2222_ = loc_2222_, loc_2223_;
										loc_2222_, loc_2220_ = loc_2220_, loc_2222_;
										if rt_equal_i32(loc_2227_, 0) then
											loc_2218_, loc_2227_ = loc_2227_, loc_2218_;
											loc_2218_ = 0;
										else
											loc_2228_ = loc_2212_;
											loc_2218_, loc_2227_ = loc_2227_, loc_2218_;
											loc_2212_ = 29084;
											repeat
												rt_yield_budget = rt_yield_budget - 1
												if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
												loc_2228_ = buffer_read_i32(loc_2214_[1], loc_2212_, 0);
												if rt_less_than_u32(loc_2218_, loc_2228_) then
													loc_2217_ = loc_2226_;
													loc_2226_ = loc_2228_;
													loc_2226_ = 0;
												else
													loc_2217_ = loc_2226_;
													loc_2226_ = loc_2228_;
													loc_2228_ = buffer_read_i32(loc_2214_[1], loc_2212_, 4);
													if rt_less_than_u32(loc_2218_, bit32_or(loc_2226_ + loc_2228_, 0)) then
														loc_2226_ = loc_2217_;
														loc_2226_ = 1;
														loc_2217_ = 0;
														loc_2224_ = 0;
													else
														loc_2226_ = 0;
													end
												end
												if not (rt_not_equal_i32(loc_2226_, 0)) then
													loc_2226_ = loc_2217_;
													loc_2212_ = buffer_read_i32(loc_2214_[1], loc_2212_, 8);
													if rt_not_equal_i32(loc_2212_, 0) then
														loc_2217_ = 1;
														loc_2224_ = 65535;
													else
														loc_2217_ = 0;
														loc_2224_ = 1;
													end
												end
												loc_2226_ = loc_2217_;
											until loc_2217_ == 0
											if rt_not_equal_i32(loc_2224_, 0) then
												loc_2218_ = 0;
											else
												loc_2221_ = rt_and_i32(bit32_or(loc_2220_ - loc_2223_, 0), loc_2221_);
												if rt_greater_than_u32(loc_2221_, 2147483646) then
													loc_2218_ = 2;
												else
													loc_2220_ = loc_2211_;
													loc_2220_ = loc_2215_[1](loc_2221_, loc_2220_)
													loc_2217_ = buffer_read_i32(loc_2214_[1], loc_2212_, 0);
													loc_2218_ = buffer_read_i32(loc_2214_[1], loc_2212_, 4);
													if rt_equal_i32(loc_2220_, bit32_or(loc_2217_ + loc_2218_, 0)) then
														if rt_not_equal_i32(loc_2220_, -1) then
															loc_2218_ = 3;
														else
															loc_2218_ = 2;
														end
													else
														loc_2218_ = loc_2212_;
														loc_2218_ = 1;
														loc_2212_ = loc_2220_;
													end
												end
											end
										end
										if (loc_2218_) >= 0 and (loc_2218_) < 3 then
											if (loc_2218_) < 1 then
												loc_2220_ = loc_2211_;
												loc_2220_ = loc_2215_[1](0, loc_2220_)
												if rt_equal_i32(loc_2220_, -1) then
													loc_2218_ = 1;
												else
													loc_2218_ = loc_2221_;
													loc_2221_ = loc_2212_;
													loc_2212_ = buffer_read_i32(loc_2214_[1], 0, 29112);
													loc_2218_ = bit32_or(loc_2212_ + -1, 0);
													if rt_equal_i32(rt_and_i32(loc_2218_, loc_2220_), 0) then
														loc_2221_ = loc_2219_;
													else
														loc_2217_ = loc_2219_;
														loc_2221_ = loc_2212_;
														loc_2212_ = loc_2221_;
														loc_2221_ = bit32_or(bit32_or(loc_2219_ - loc_2220_, 0) + rt_and_i32(bit32_or(loc_2218_ + loc_2220_, 0), bit32_or(0 - loc_2221_, 0)), 0);
													end
													if rt_less_than_equal_u32(loc_2221_, loc_2222_) then
														loc_2218_ = 1;
													else
														if rt_greater_than_u32(loc_2221_, 2147483646) then
															loc_2218_ = 1;
														else
															loc_2218_ = loc_2212_;
															loc_2212_ = buffer_read_i32(loc_2214_[1], 0, 29076);
															if rt_equal_i32(loc_2212_, 0) then
																loc_2218_ = 0;
															else
																loc_2218_ = buffer_read_i32(loc_2214_[1], 0, 29068);
																loc_2223_ = bit32_or(loc_2218_ + loc_2221_, 0);
																if rt_less_than_equal_u32(loc_2223_, loc_2218_) then
																	loc_2218_ = 1;
																else
																	if rt_greater_than_u32(loc_2223_, loc_2212_) then
																		loc_2218_ = 2;
																	else
																		loc_2218_ = 0;
																	end
																end
															end
															if (loc_2218_) >= 0 and (loc_2218_) < 2 then
																if (loc_2218_) < 1 then
																	loc_2218_ = loc_2212_;
																	loc_2218_ = loc_2211_;
																	loc_2212_ = loc_2215_[1](loc_2221_, loc_2218_)
																	if rt_not_equal_i32(loc_2212_, loc_2220_) then
																		loc_2218_ = 0;
																	else
																		loc_2218_ = 2;
																	end
																else
																	loc_2218_ = 1;
																end
															else
																loc_2218_ = 1;
															end
														end
													end
												end
											elseif (loc_2218_) > 1 then
												loc_2218_ = 1;
											else
												loc_2218_ = 0;
											end
										else
											loc_2218_ = 3;
										end
										if (loc_2218_) >= 0 and (loc_2218_) < 3 then
											if (loc_2218_) < 1 then
												if rt_greater_than_equal_u32(loc_2221_, bit32_or(loc_2222_ + 72, 0)) then
													loc_2227_ = 0;
												else
													if rt_equal_i32(loc_2212_, -1) then
														loc_2227_ = 0;
													else
														loc_2218_ = buffer_read_i32(loc_2214_[1], 0, 29116);
														loc_2217_ = rt_and_i32(bit32_or(bit32_or(loc_2227_ - loc_2221_, 0) + loc_2218_, 0), bit32_or(0 - loc_2218_, 0));
														if rt_less_than_equal_u32(loc_2217_, 2147483646) then
															loc_2218_ = loc_2215_;
															loc_2227_ = loc_2211_;
															loc_2215_ = loc_2218_[1](loc_2217_, loc_2227_)
															if rt_equal_i32(loc_2215_, -1) then
																loc_2215_ = loc_2218_;
																loc_2227_ = loc_2218_[1](bit32_or(0 - loc_2221_, 0), loc_2227_)
																loc_2227_ = 1;
															else
																loc_2215_ = loc_2220_;
																loc_2220_ = loc_2212_;
																loc_2218_, loc_2227_ = loc_2227_, loc_2218_;
																loc_2215_ = loc_2227_;
																loc_2227_ = 2;
																loc_2212_ = loc_2220_;
																loc_2221_ = bit32_or(loc_2217_ + loc_2221_, 0);
																loc_2211_ = loc_2218_;
															end
														else
															loc_2218_ = loc_2211_;
															loc_2227_ = loc_2215_;
															loc_2215_ = loc_2220_;
															loc_2220_ = loc_2212_;
															loc_2215_ = loc_2227_;
															loc_2227_ = 3;
															loc_2212_ = loc_2220_;
															loc_2211_ = loc_2218_;
														end
													end
												end
												if (loc_2227_) >= 0 and (loc_2227_) < 3 then
													if (loc_2227_) < 1 then
														loc_2227_ = loc_2220_;
														if rt_not_equal_i32(loc_2212_, -1) then
															loc_2220_ = loc_2212_;
															loc_2227_ = 4;
														else
															loc_2220_ = loc_2212_;
															loc_2227_ = 0;
														end
													elseif (loc_2227_) > 1 then
														loc_2227_ = 3;
													else
														loc_2227_ = 0;
													end
												else
													loc_2227_ = 2;
												end
											elseif (loc_2218_) > 1 then
												loc_2227_ = 1;
											else
												loc_2227_ = 0;
											end
										else
											loc_2227_ = 5;
										end
										if (loc_2227_) >= 0 and (loc_2227_) < 5 then
											if (loc_2227_) < 2 then
												if (loc_2227_) < 1 then
													loc_2227_ = buffer_read_i32(loc_2214_[1], 0, 29080);
													rt_store_i32(loc_2214_, 0, 29080, rt_or_i32(loc_2227_, 4))
													loc_2227_ = 0;
												else
													loc_2227_ = 1;
												end
											elseif (loc_2227_) > 2 then
												if (loc_2227_) < 4 then
													loc_2227_ = 1;
												else
													loc_2227_ = 1;
												end
											else
												loc_2227_ = 1;
											end
										else
											loc_2227_ = 1;
										end
									end
									if rt_not_equal_i32(loc_2227_, 0) then
										loc_2227_ = 0;
									else
										if rt_greater_than_u32(loc_2219_, 2147483646) then
											loc_2227_ = 1;
										else
											loc_2227_ = loc_2212_;
											loc_2227_ = loc_2211_;
											loc_2220_ = loc_2215_[1](loc_2219_, loc_2227_)
											loc_2212_ = loc_2215_[1](0, loc_2227_)
											if rt_equal_i32(loc_2220_, -1) then
												loc_2227_ = 1;
											else
												if rt_equal_i32(loc_2212_, -1) then
													loc_2227_ = 1;
												else
													if rt_greater_than_equal_u32(loc_2220_, loc_2212_) then
														loc_2227_ = 1;
													else
														loc_2227_ = loc_2221_;
														loc_2221_ = bit32_or(loc_2212_ - loc_2220_, 0);
														if rt_less_than_equal_u32(loc_2221_, bit32_or(loc_2222_ + 56, 0)) then
															loc_2227_ = 1;
														else
															loc_2227_ = 0;
														end
													end
												end
											end
										end
									end
									if rt_not_equal_i32(loc_2227_, 0) then
										loc_2226_ = 0;
									else
										loc_2227_ = loc_2212_;
										loc_2227_ = buffer_read_i32(loc_2214_[1], 0, 29068);
										loc_2227_ = bit32_or(loc_2227_ + loc_2221_, 0);
										rt_store_i32(loc_2214_, 0, 29068, loc_2227_)
										loc_2218_ = buffer_read_i32(loc_2214_[1], 0, 29072);
										if rt_less_than_equal_u32(loc_2227_, loc_2218_) then
											loc_2218_ = loc_2219_;
											loc_2220_, loc_2223_ = loc_2223_, loc_2220_;
											loc_2221_, loc_2224_ = loc_2224_, loc_2221_;
											loc_2222_, loc_2226_ = loc_2226_, loc_2222_;
										else
											loc_2218_ = loc_2219_;
											loc_2220_, loc_2223_ = loc_2223_, loc_2220_;
											loc_2221_, loc_2224_ = loc_2224_, loc_2221_;
											loc_2222_, loc_2226_ = loc_2226_, loc_2222_;
											rt_store_i32(loc_2214_, 0, 29072, loc_2227_)
										end
										loc_2219_ = buffer_read_i32(loc_2214_[1], 0, 28660);
										if rt_equal_i32(loc_2219_, 0) then
											loc_2222_ = buffer_read_i32(loc_2214_[1], 0, 28652);
											if rt_equal_i32(loc_2222_, 0) then
												loc_2222_ = 0;
											else
												if rt_greater_than_equal_u32(loc_2223_, loc_2222_) then
													loc_2222_ = 1;
												else
													loc_2222_ = 0;
												end
											end
											if not (rt_not_equal_i32(loc_2222_, 0)) then
												rt_store_i32(loc_2214_, 0, 28652, loc_2223_)
											end
											rt_store_i32(loc_2214_, 0, 29088, loc_2224_)
											rt_store_i32(loc_2214_, 0, 29084, loc_2223_)
											rt_store_i32(loc_2214_, 0, 28668, -1)
											loc_2222_ = buffer_read_i32(loc_2214_[1], 0, 29108);
											rt_store_i32(loc_2214_, 0, 28672, loc_2222_)
											rt_store_i32(loc_2214_, 0, 29096, 0)
											loc_2222_ = 0;
											repeat
												rt_yield_budget = rt_yield_budget - 1
												if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
												loc_2221_ = bit32_or(loc_2222_ + 28684, 0);
												rt_store_i32(loc_2214_, bit32_or(loc_2222_ + 28696, 0), 0, loc_2221_)
												loc_2220_ = bit32_or(loc_2222_ + 28676, 0);
												rt_store_i32(loc_2214_, loc_2221_, 0, loc_2220_)
												rt_store_i32(loc_2214_, bit32_or(loc_2222_ + 28688, 0), 0, loc_2220_)
												loc_2220_ = bit32_or(loc_2222_ + 28692, 0);
												rt_store_i32(loc_2214_, bit32_or(loc_2222_ + 28704, 0), 0, loc_2220_)
												rt_store_i32(loc_2214_, loc_2220_, 0, loc_2221_)
												loc_2221_ = bit32_or(loc_2222_ + 28700, 0);
												rt_store_i32(loc_2214_, bit32_or(loc_2222_ + 28712, 0), 0, loc_2221_)
												rt_store_i32(loc_2214_, loc_2221_, 0, loc_2220_)
												rt_store_i32(loc_2214_, bit32_or(loc_2222_ + 28708, 0), 0, loc_2221_)
												loc_2221_ = bit32_or(loc_2222_ + 32, 0);
												loc_2222_ = loc_2221_;
											until not (rt_not_equal_i32(loc_2221_, 256))
											loc_2221_ = rt_and_i32(bit32_or(-8 - loc_2223_, 0), 15);
											loc_2222_ = bit32_or(loc_2223_ + loc_2221_, 0);
											loc_2224_ = bit32_or(loc_2224_ + -56, 0);
											loc_2212_ = bit32_or(loc_2224_ - loc_2221_, 0);
											rt_store_i32(loc_2214_, loc_2222_, 4, rt_or_i32(loc_2212_, 1))
											loc_2221_ = buffer_read_i32(loc_2214_[1], 0, 29124);
											rt_store_i32(loc_2214_, 0, 28664, loc_2221_)
											rt_store_i32(loc_2214_, 0, 28648, loc_2212_)
											rt_store_i32(loc_2214_, 0, 28660, loc_2222_)
											rt_store_i32(loc_2214_, bit32_or(loc_2223_ + loc_2224_, 0), 4, 56)
											loc_2224_ = 0;
										else
											loc_2227_ = loc_2220_;
											loc_2220_ = loc_2223_;
											loc_2223_ = loc_2221_;
											loc_2221_ = loc_2224_;
											loc_2224_ = loc_2222_;
											loc_2222_ = loc_2219_;
											loc_2212_ = 29084;
											loc_2219_ = loc_2218_;
											repeat
												rt_yield_budget = rt_yield_budget - 1
												if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
												loc_2223_, loc_2227_ = loc_2227_, loc_2223_;
												loc_2227_, loc_2224_ = loc_2224_, loc_2227_;
												loc_2227_ = buffer_read_i32(loc_2214_[1], loc_2212_, 0);
												loc_2219_ = buffer_read_i32(loc_2214_[1], loc_2212_, 4);
												if rt_equal_i32(loc_2220_, bit32_or(loc_2227_ + loc_2219_, 0)) then
													loc_2218_ = 0;
													loc_2223_ = 1;
												else
													loc_2212_ = buffer_read_i32(loc_2214_[1], loc_2212_, 8);
													if rt_not_equal_i32(loc_2212_, 0) then
														loc_2218_ = 1;
														loc_2223_ = 65535;
													else
														loc_2218_ = 0;
														loc_2223_ = 0;
													end
												end
												loc_2224_ = loc_2218_;
											until loc_2218_ == 0
											if rt_not_equal_i32(loc_2223_, 0) then
												if rt_greater_than_equal_u32(loc_2222_, loc_2220_) then
													loc_2227_ = 0;
												else
													if rt_less_than_u32(loc_2222_, loc_2227_) then
														loc_2227_ = 0;
													else
														loc_2227_ = buffer_read_i32(loc_2214_[1], loc_2212_, 12);
														if rt_not_equal_i32(rt_and_i32(loc_2227_, 8), 0) then
															loc_2227_ = 0;
														else
															loc_2227_ = loc_2220_;
															loc_2227_ = buffer_read_i32(loc_2214_[1], 0, 28648);
															loc_2218_ = rt_and_i32(bit32_or(-8 - loc_2222_, 0), 15);
															loc_2220_ = bit32_or(loc_2222_ + loc_2218_, 0);
															loc_2227_ = bit32_or(loc_2227_ + loc_2221_, 0);
															loc_2218_ = bit32_or(loc_2227_ - loc_2218_, 0);
															rt_store_i32(loc_2214_, loc_2220_, 4, rt_or_i32(loc_2218_, 1))
															rt_store_i32(loc_2214_, loc_2212_, 4, bit32_or(loc_2219_ + loc_2221_, 0))
															loc_2217_ = buffer_read_i32(loc_2214_[1], 0, 29124);
															rt_store_i32(loc_2214_, 0, 28664, loc_2217_)
															rt_store_i32(loc_2214_, 0, 28648, loc_2218_)
															rt_store_i32(loc_2214_, 0, 28660, loc_2220_)
															rt_store_i32(loc_2214_, bit32_or(loc_2222_ + loc_2227_, 0), 4, 56)
															loc_2227_ = 1;
														end
													end
												end
											else
												loc_2227_ = 0;
											end
											if rt_not_equal_i32(loc_2227_, 0) then
												loc_2224_ = 0;
											else
												loc_2227_ = loc_2212_;
												loc_2227_ = buffer_read_i32(loc_2214_[1], 0, 28652);
												if rt_greater_than_equal_u32(loc_2220_, loc_2227_) then
													loc_2212_ = loc_2216_;
													loc_2217_ = loc_2219_;
													loc_2218_ = loc_2211_;
													loc_2219_ = loc_2220_;
													loc_2220_ = loc_2221_;
													loc_2221_ = loc_2222_;
												else
													loc_2212_ = loc_2216_;
													loc_2217_ = loc_2219_;
													loc_2218_ = loc_2211_;
													loc_2219_ = loc_2220_;
													loc_2220_ = loc_2221_;
													loc_2221_ = loc_2222_;
													rt_store_i32(loc_2214_, 0, 28652, loc_2219_)
												end
												loc_2222_ = bit32_or(loc_2219_ + loc_2220_, 0);
												loc_2227_ = 29084;
												repeat
													rt_yield_budget = rt_yield_budget - 1
													if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
													loc_2217_ = buffer_read_i32(loc_2214_[1], loc_2227_, 0);
													if rt_equal_i32(loc_2217_, loc_2222_) then
														loc_2216_ = 0;
														loc_2223_ = 1;
													else
														loc_2227_ = buffer_read_i32(loc_2214_[1], loc_2227_, 8);
														if rt_not_equal_i32(loc_2227_, 0) then
															loc_2216_ = 1;
															loc_2223_ = 65535;
														else
															loc_2216_ = 0;
															loc_2223_ = 0;
														end
													end
													loc_2224_ = loc_2216_;
												until loc_2216_ == 0
												if rt_not_equal_i32(loc_2223_, 0) then
													loc_2216_ = rt_load_i32_from_u8(loc_2214_, loc_2227_, 12);
													if rt_equal_i32(rt_and_i32(loc_2216_, 8), 0) then
														loc_2216_ = loc_2212_;
														rt_store_i32(loc_2214_, loc_2227_, 0, loc_2219_)
														loc_2211_ = buffer_read_i32(loc_2214_[1], loc_2227_, 4);
														rt_store_i32(loc_2214_, loc_2227_, 4, bit32_or(loc_2211_ + loc_2220_, 0))
														loc_2212_ = loc_2212_[1](loc_2219_, loc_2217_, loc_2226_, loc_2218_)
														loc_2218_ = 1;
													else
														loc_2217_, loc_2227_ = loc_2227_, loc_2217_;
														loc_2227_, loc_2218_ = loc_2218_, loc_2227_;
														loc_2216_ = loc_2212_;
														loc_2218_ = 0;
														loc_2212_ = loc_2217_;
														loc_2211_ = loc_2227_;
													end
												else
													loc_2217_, loc_2227_ = loc_2227_, loc_2217_;
													loc_2227_, loc_2218_ = loc_2218_, loc_2227_;
													loc_2216_ = loc_2212_;
													loc_2218_ = 0;
													loc_2212_ = loc_2217_;
													loc_2211_ = loc_2227_;
												end
												if rt_not_equal_i32(loc_2218_, 0) then
													loc_2224_ = 1;
												else
													loc_2218_ = loc_2212_;
													loc_2219_, loc_2220_ = loc_2220_, loc_2219_;
													loc_2221_, loc_2222_ = loc_2222_, loc_2221_;
													loc_2223_, loc_2224_ = loc_2224_, loc_2223_;
													loc_2218_ = 29084;
													repeat
														rt_yield_budget = rt_yield_budget - 1
														if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
														loc_2221_ = buffer_read_i32(loc_2214_[1], loc_2218_, 0);
														if rt_less_than_u32(loc_2222_, loc_2221_) then
															loc_2217_ = loc_2223_;
															loc_2223_ = 0;
														else
															loc_2217_ = loc_2223_;
															loc_2223_ = buffer_read_i32(loc_2214_[1], loc_2218_, 4);
															loc_2221_ = bit32_or(loc_2221_ + loc_2223_, 0);
															if rt_less_than_u32(loc_2222_, loc_2221_) then
																loc_2223_ = loc_2217_;
																loc_2223_ = 1;
																loc_2217_ = 0;
															else
																loc_2223_ = 0;
															end
														end
														if not (rt_not_equal_i32(loc_2223_, 0)) then
															loc_2223_ = loc_2224_;
															loc_2224_ = loc_2217_;
															loc_2218_ = buffer_read_i32(loc_2214_[1], loc_2218_, 8);
															loc_2217_ = 1;
															loc_2224_ = 65535;
														end
														loc_2223_ = loc_2217_;
													until loc_2217_ == 0
													loc_2217_ = rt_and_i32(bit32_or(-8 - loc_2220_, 0), 15);
													loc_2218_ = bit32_or(loc_2220_ + loc_2217_, 0);
													loc_2223_ = bit32_or(loc_2219_ + -56, 0);
													loc_2217_ = bit32_or(loc_2223_ - loc_2217_, 0);
													rt_store_i32(loc_2214_, loc_2218_, 4, rt_or_i32(loc_2217_, 1))
													rt_store_i32(loc_2214_, bit32_or(loc_2220_ + loc_2223_, 0), 4, 56)
													loc_2212_ = bit32_or(bit32_or(loc_2221_ + rt_and_i32(bit32_or(55 - loc_2221_, 0), 15), 0) + -63, 0);
													if rt_less_than_u32(loc_2212_, bit32_or(loc_2222_ + 16, 0)) then
														loc_2223_ = loc_2222_;
													else
														loc_2223_ = loc_2222_;
														loc_2222_ = loc_2212_;
													end
													rt_store_i32(loc_2214_, loc_2222_, 4, 35)
													loc_2212_ = buffer_read_i32(loc_2214_[1], 0, 29124);
													rt_store_i32(loc_2214_, 0, 28664, loc_2212_)
													rt_store_i32(loc_2214_, 0, 28648, loc_2217_)
													rt_store_i32(loc_2214_, 0, 28660, loc_2218_)
													loc_2218_ = rt_load_i64(loc_2214_, 0, 29092);
													rt_store_i64(loc_2214_, bit32_or(loc_2222_ + 16, 0), 0, loc_2218_)
													loc_2218_ = rt_load_i64(loc_2214_, 0, 29084);
													rt_store_i64(loc_2214_, loc_2222_, 8, loc_2218_)
													rt_store_i32(loc_2214_, 0, 29092, bit32_or(loc_2222_ + 8, 0))
													rt_store_i32(loc_2214_, 0, 29088, loc_2219_)
													rt_store_i32(loc_2214_, 0, 29084, loc_2220_)
													rt_store_i32(loc_2214_, 0, 29096, 0)
													loc_2212_ = bit32_or(loc_2222_ + 36, 0);
													repeat
														rt_yield_budget = rt_yield_budget - 1
														if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
														loc_2219_ = loc_2221_;
														rt_store_i32(loc_2214_, loc_2212_, 0, 7)
														loc_2221_ = loc_2219_;
														loc_2220_ = bit32_or(loc_2212_ + 4, 0);
														loc_2212_ = loc_2220_;
													until not (rt_less_than_u32(loc_2220_, loc_2219_))
													if rt_equal_i32(loc_2222_, loc_2223_) then
														loc_2224_ = 0;
													else
														loc_2221_ = loc_2212_;
														loc_2221_ = buffer_read_i32(loc_2214_[1], loc_2222_, 4);
														rt_store_i32(loc_2214_, loc_2222_, 4, rt_and_i32(loc_2221_, -2))
														loc_2217_ = bit32_or(loc_2222_ - loc_2223_, 0);
														rt_store_i32(loc_2214_, loc_2222_, 0, loc_2217_)
														rt_store_i32(loc_2214_, loc_2223_, 4, rt_or_i32(loc_2217_, 1))
														if rt_greater_than_u32(loc_2217_, 255) then
															loc_2218_ = loc_2224_;
															loc_2220_ = 31;
															if not (rt_greater_than_u32(loc_2217_, 16777215)) then
																loc_2224_ = loc_2220_;
																loc_2224_ = rt_leading_zeroes_i32(rt_shift_right_u32(loc_2217_, 8));
																loc_2220_ = bit32_or(bit32_or(rt_and_i32(rt_shift_right_u32(loc_2217_, bit32_or(38 - loc_2224_, 0)), 1) - rt_shift_left_i32(loc_2224_, 1), 0) + 62, 0);
															end
															rt_store_i32(loc_2214_, loc_2223_, 28, loc_2220_)
															rt_store_i64(loc_2214_, loc_2223_, 16, into_bits_i64(0, 0))
															loc_2224_ = buffer_read_i32(loc_2214_[1], 0, 28640);
															loc_2221_ = bit32_or(rt_shift_left_i32(loc_2220_, 2) + 28940, 0);
															loc_2222_ = rt_shift_left_i32(1, loc_2220_);
															if rt_not_equal_i32(rt_and_i32(loc_2224_, loc_2222_), 0) then
																loc_2224_ = 0;
																loc_2219_ = bit32_or(25 - rt_shift_right_u32(loc_2220_, 1), 0);
																if rt_equal_i32(loc_2220_, 31) then
																	loc_2220_ = loc_2217_;
																else
																	loc_2220_ = loc_2217_;
																	loc_2224_ = loc_2219_;
																end
																loc_2219_ = buffer_read_i32(loc_2214_[1], loc_2221_, 0);
																loc_2224_ = rt_shift_left_i32(loc_2217_, loc_2224_);
																repeat
																	rt_yield_budget = rt_yield_budget - 1
																	if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
																	loc_2218_, loc_2221_ = loc_2221_, loc_2218_;
																	loc_2221_ = buffer_read_i32(loc_2214_[1], loc_2219_, 4);
																	if rt_equal_i32(rt_and_i32(loc_2221_, -8), loc_2220_) then
																		loc_2221_ = loc_2219_;
																		loc_2217_ = 0;
																		loc_2218_ = 1;
																	else
																		loc_2221_ = loc_2219_;
																		loc_2222_ = bit32_or(loc_2221_ + rt_and_i32(rt_shift_right_u32(loc_2224_, 29), 4), 0);
																		loc_2219_ = buffer_read_i32(loc_2214_[1], loc_2222_, 16);
																		loc_2224_ = rt_shift_left_i32(loc_2224_, 1);
																		if rt_not_equal_i32(loc_2219_, 0) then
																			loc_2217_ = 1;
																			loc_2218_ = 65535;
																		else
																			loc_2217_ = 0;
																			loc_2218_ = 0;
																		end
																	end
																until loc_2217_ == 0
																if rt_not_equal_i32(loc_2218_, 0) then
																	loc_2224_ = buffer_read_i32(loc_2214_[1], loc_2221_, 8);
																	rt_store_i32(loc_2214_, loc_2221_, 8, loc_2223_)
																	rt_store_i32(loc_2214_, loc_2224_, 12, loc_2223_)
																	rt_store_i32(loc_2214_, loc_2223_, 8, loc_2224_)
																	loc_2220_ = 1;
																	loc_2212_ = 0;
																	loc_2224_ = 24;
																	loc_2222_ = 12;
																else
																	loc_2220_, loc_2222_ = loc_2222_, loc_2220_;
																	loc_2222_, loc_2224_ = loc_2224_, loc_2222_;
																	rt_store_i32(loc_2214_, bit32_or(loc_2220_ + 16, 0), 0, loc_2223_)
																	rt_store_i32(loc_2214_, loc_2223_, 24, loc_2221_)
																	loc_2220_ = 0;
																	loc_2212_ = loc_2222_;
																	loc_2222_ = loc_2219_;
																end
															else
																loc_2219_ = loc_2218_;
																loc_2220_, loc_2222_ = loc_2222_, loc_2220_;
																loc_2222_, loc_2224_ = loc_2224_, loc_2222_;
																rt_store_i32(loc_2214_, loc_2221_, 0, loc_2223_)
																rt_store_i32(loc_2214_, 0, 28640, rt_or_i32(loc_2222_, loc_2220_))
																rt_store_i32(loc_2214_, loc_2223_, 24, loc_2221_)
																loc_2220_ = 0;
																loc_2212_ = loc_2224_;
																loc_2224_ = loc_2217_;
															end
															if not (rt_not_equal_i32(loc_2220_, 0)) then
																loc_2220_ = loc_2222_;
																loc_2222_ = loc_2212_;
																loc_2221_, loc_2224_ = loc_2224_, loc_2221_;
																loc_2224_, loc_2223_ = loc_2223_, loc_2224_;
																loc_2221_ = loc_2224_;
																loc_2223_ = loc_2224_;
																loc_2212_ = loc_2224_;
																loc_2224_ = 8;
																loc_2222_ = 12;
															end
														else
															loc_2224_ = buffer_read_i32(loc_2214_[1], 0, 28636);
															loc_2212_ = bit32_or(rt_and_i32(loc_2217_, -8) + 28676, 0);
															loc_2222_ = rt_shift_left_i32(1, rt_shift_right_u32(loc_2217_, 3));
															if rt_not_equal_i32(rt_and_i32(loc_2224_, loc_2222_), 0) then
																loc_2221_ = buffer_read_i32(loc_2214_[1], loc_2212_, 8);
															else
																rt_store_i32(loc_2214_, 0, 28636, rt_or_i32(loc_2224_, loc_2222_))
																loc_2221_ = loc_2212_;
															end
															rt_store_i32(loc_2214_, loc_2221_, 12, loc_2223_)
															rt_store_i32(loc_2214_, loc_2212_, 8, loc_2223_)
															loc_2224_ = 12;
															loc_2222_ = 8;
														end
														rt_store_i32(loc_2214_, bit32_or(loc_2223_ + loc_2222_, 0), 0, loc_2221_)
														rt_store_i32(loc_2214_, bit32_or(loc_2223_ + loc_2224_, 0), 0, loc_2212_)
														loc_2224_ = 0;
													end
												end
											end
										end
										if rt_not_equal_i32(loc_2224_, 0) then
											loc_2226_ = 1;
										else
											loc_2224_ = loc_2212_;
											loc_2212_ = buffer_read_i32(loc_2214_[1], 0, 28648);
											if rt_less_than_equal_u32(loc_2212_, loc_2226_) then
												loc_2226_ = 0;
											else
												loc_2224_ = buffer_read_i32(loc_2214_[1], 0, 28660);
												loc_2223_ = bit32_or(loc_2224_ + loc_2226_, 0);
												loc_2222_ = bit32_or(loc_2212_ - loc_2226_, 0);
												rt_store_i32(loc_2214_, loc_2223_, 4, rt_or_i32(loc_2222_, 1))
												rt_store_i32(loc_2214_, 0, 28648, loc_2222_)
												rt_store_i32(loc_2214_, 0, 28660, loc_2223_)
												rt_store_i32(loc_2214_, loc_2224_, 4, rt_or_i32(loc_2226_, 3))
												loc_2226_ = 1;
												loc_2212_ = bit32_or(loc_2224_ + 8, 0);
											end
										end
									end
									if not (rt_not_equal_i32(loc_2226_, 0)) then
										loc_2226_ = loc_2212_;
										rt_store_i32(loc_2214_, 0, 27520, 48)
										loc_2212_ = 0;
									end
								end
							else
								loc_2227_ = loc_2224_;
								loc_2224_ = loc_2222_;
								loc_2222_ = loc_2220_;
								loc_2220_ = loc_2218_;
								loc_2218_ = loc_2226_;
								loc_2226_ = loc_2223_;
								loc_2223_ = loc_2221_;
								loc_2221_ = loc_2219_;
								loc_2219_ = loc_2217_;
								rt_store_i32(loc_2214_, 0, 27520, 48)
								loc_2212_ = loc_2228_;
							end
						else
							loc_2227_ = loc_2223_;
							loc_2228_ = loc_2224_;
							loc_2227_ = bit32_or(loc_2221_ + loc_2220_, 0);
							loc_2228_ = bit32_or(loc_2222_ - loc_2220_, 0);
							rt_store_i32(loc_2214_, loc_2227_, 4, rt_or_i32(loc_2228_, 1))
							rt_store_i32(loc_2214_, 0, 28660, loc_2227_)
							rt_store_i32(loc_2214_, 0, 28648, loc_2228_)
							rt_store_i32(loc_2214_, loc_2221_, 4, rt_or_i32(loc_2220_, 3))
							loc_2212_ = bit32_or(loc_2221_ + 8, 0);
						end
					else
						loc_2220_ = loc_2221_;
						loc_2226_ = loc_2223_;
						loc_2227_ = loc_2228_;
						loc_2228_ = loc_2224_;
						loc_2224_ = loc_2222_;
						loc_2228_ = buffer_read_i32(loc_2214_[1], 0, 28656);
						loc_2226_ = bit32_or(loc_2227_ - loc_2220_, 0);
						if rt_less_than_u32(loc_2226_, 16) then
							loc_2224_ = loc_2220_;
							rt_store_i32(loc_2214_, loc_2228_, 4, rt_or_i32(loc_2227_, 3))
							loc_2226_ = bit32_or(loc_2228_ + loc_2227_, 0);
							loc_2227_ = buffer_read_i32(loc_2214_[1], loc_2226_, 4);
							rt_store_i32(loc_2214_, loc_2226_, 4, rt_or_i32(loc_2227_, 1))
							loc_2226_ = 0;
							loc_2227_ = 0;
						else
							loc_2223_ = loc_2227_;
							loc_2224_ = loc_2220_;
							loc_2227_ = bit32_or(loc_2228_ + loc_2224_, 0);
							rt_store_i32(loc_2214_, loc_2227_, 4, rt_or_i32(loc_2226_, 1))
							rt_store_i32(loc_2214_, bit32_or(loc_2228_ + loc_2223_, 0), 0, loc_2226_)
							rt_store_i32(loc_2214_, loc_2228_, 4, rt_or_i32(loc_2224_, 3))
						end
						rt_store_i32(loc_2214_, 0, 28644, loc_2226_)
						rt_store_i32(loc_2214_, 0, 28656, loc_2227_)
						loc_2212_ = bit32_or(loc_2228_ + 8, 0);
					end
				end
				loc_2213_[1] = bit32_or(loc_2225_ + 16, 0);
			end
			return loc_2212_, loc_2211_
		end), "i32->i32")
	end)(module_locals[155], module_locals[158], module_locals[164], module_locals[3]);
	do (function() --[[spider:chunk]]
	module_locals[158][1] = (function(loc_2231_)
		return rt_function_type(--[[fn:prepend_alloc]](function(loc_2232_, loc_2233_, loc_2234_, loc_2235_)
			local loc_2236_, loc_2237_, loc_2238_, loc_2239_, loc_2240_, loc_2241_, loc_2242_, loc_2243_, loc_2244_, loc_2245_, loc_2246_, loc_2247_, loc_2248_, loc_2249_
			loc_2237_ = bit32_or(loc_2232_ + rt_and_i32(bit32_or(-8 - loc_2232_, 0), 15), 0);
			rt_store_i32(loc_2231_, loc_2237_, 4, rt_or_i32(loc_2234_, 3))
			loc_2238_ = loc_2231_;
			loc_2249_ = buffer_read_i32(loc_2238_[1], 0, 28660);
			loc_2242_ = 0;
			loc_2246_ = bit32_or(loc_2233_ + rt_and_i32(bit32_or(-8 - loc_2233_, 0), 15), 0);
			loc_2240_ = bit32_or(loc_2237_ + loc_2234_, 0);
			loc_2244_ = bit32_or(loc_2246_ - loc_2240_, 0);
			loc_2243_ = 0;
			loc_2241_ = 0;
			if rt_not_equal_i32(loc_2246_, loc_2249_) then
				loc_2236_ = loc_2235_;
				loc_2249_ = buffer_read_i32(loc_2238_[1], 0, 28656);
				if rt_not_equal_i32(loc_2246_, loc_2249_) then
					loc_2245_ = buffer_read_i32(loc_2238_[1], loc_2246_, 4);
					if not (rt_not_equal_i32(rt_and_i32(loc_2245_, 3), 1)) then
						loc_2249_ = buffer_read_i32(loc_2238_[1], loc_2246_, 12);
						loc_2248_ = rt_and_i32(loc_2245_, -8);
						if rt_greater_than_u32(loc_2245_, 255) then
							loc_2239_ = loc_2241_;
							loc_2247_ = loc_2243_;
							loc_2243_ = loc_2244_;
							loc_2244_ = loc_2248_;
							loc_2248_ = loc_2245_;
							loc_2241_ = buffer_read_i32(loc_2238_[1], loc_2246_, 24);
							if rt_equal_i32(loc_2249_, loc_2246_) then
								loc_2248_ = buffer_read_i32(loc_2238_[1], loc_2246_, 20);
								if rt_equal_i32(loc_2248_, 0) then
									loc_2248_ = buffer_read_i32(loc_2238_[1], loc_2246_, 16);
									if rt_equal_i32(loc_2248_, 0) then
										loc_2249_ = 1;
										loc_2245_ = 0;
									else
										loc_2246_, loc_2249_ = loc_2249_, loc_2246_;
										loc_2249_, loc_2247_ = loc_2247_, loc_2249_;
										loc_2249_ = 0;
										loc_2245_ = loc_2246_;
										loc_2246_ = loc_2247_;
										loc_2247_ = bit32_or(loc_2247_ + 16, 0);
									end
								else
									loc_2246_, loc_2249_ = loc_2249_, loc_2246_;
									loc_2249_, loc_2247_ = loc_2247_, loc_2249_;
									loc_2249_ = 0;
									loc_2245_ = loc_2246_;
									loc_2246_ = loc_2247_;
									loc_2247_ = bit32_or(loc_2247_ + 20, 0);
								end
								if not (rt_not_equal_i32(loc_2249_, 0)) then
									loc_2249_ = loc_2239_;
									loc_2247_, loc_2248_ = loc_2248_, loc_2247_;
									loc_2239_ = loc_2248_;
									loc_2248_ = loc_2249_;
									repeat
										rt_yield_budget = rt_yield_budget - 1
										if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
										loc_2249_ = loc_2239_;
										loc_2245_, loc_2248_ = loc_2248_, loc_2245_;
										loc_2248_, loc_2247_ = loc_2247_, loc_2248_;
										loc_2247_ = buffer_read_i32(loc_2238_[1], loc_2248_, 20);
										loc_2239_ = bit32_or(loc_2248_ + 20, 0);
										if rt_not_equal_i32(loc_2247_, 0) then
											loc_2245_ = loc_2248_;
											loc_2248_ = loc_2249_;
											loc_2249_ = loc_2242_;
											loc_2249_ = 1;
											loc_2242_ = 65535;
										else
											loc_2245_ = loc_2248_;
											loc_2248_ = loc_2249_;
											loc_2249_ = loc_2242_;
											loc_2242_ = loc_2239_;
											loc_2247_ = buffer_read_i32(loc_2238_[1], loc_2245_, 16);
											loc_2239_ = bit32_or(loc_2245_ + 16, 0);
											if rt_not_equal_i32(loc_2247_, 0) then
												loc_2249_ = 1;
												loc_2242_ = 65535;
											else
												loc_2242_ = loc_2249_;
												loc_2249_ = 0;
											end
										end
									until loc_2249_ == 0
									rt_store_i32(loc_2238_, loc_2248_, 0, 0)
								end
							else
								loc_2248_ = loc_2247_;
								loc_2247_ = loc_2239_;
								loc_2248_ = buffer_read_i32(loc_2238_[1], loc_2246_, 8);
								rt_store_i32(loc_2238_, loc_2248_, 12, loc_2249_)
								rt_store_i32(loc_2238_, loc_2249_, 8, loc_2248_)
								loc_2245_ = loc_2249_;
							end
							if not (rt_equal_i32(loc_2241_, 0)) then
								loc_2247_ = buffer_read_i32(loc_2238_[1], loc_2246_, 28);
								loc_2239_ = rt_shift_left_i32(loc_2247_, 2);
								loc_2248_ = buffer_read_i32(loc_2238_[1], loc_2239_, 28940);
								if rt_not_equal_i32(loc_2246_, loc_2248_) then
									loc_2239_ = buffer_read_i32(loc_2238_[1], loc_2241_, 16);
									if rt_not_equal_i32(loc_2239_, loc_2246_) then
										rt_store_i32(loc_2238_, loc_2241_, 20, loc_2245_)
									else
										rt_store_i32(loc_2238_, loc_2241_, 16, loc_2245_)
									end
									if rt_equal_i32(loc_2245_, 0) then
										loc_2239_ = 1;
									else
										loc_2239_ = 0;
									end
								else
									rt_store_i32(loc_2238_, bit32_or(loc_2239_ + 28940, 0), 0, loc_2245_)
									if rt_not_equal_i32(loc_2245_, 0) then
										loc_2239_ = 0;
									else
										loc_2239_ = buffer_read_i32(loc_2238_[1], 0, 28640);
										rt_store_i32(loc_2238_, 0, 28640, rt_and_i32(loc_2239_, rt_rotate_left_i32(-2, loc_2247_)))
										loc_2239_ = 1;
									end
								end
								if not (rt_not_equal_i32(loc_2239_, 0)) then
									loc_2241_, loc_2245_ = loc_2245_, loc_2241_;
									rt_store_i32(loc_2238_, loc_2241_, 24, loc_2245_)
									loc_2245_ = buffer_read_i32(loc_2238_[1], loc_2246_, 16);
									if not (rt_equal_i32(loc_2245_, 0)) then
										rt_store_i32(loc_2238_, loc_2241_, 16, loc_2245_)
										rt_store_i32(loc_2238_, loc_2245_, 24, loc_2241_)
									end
									loc_2245_ = buffer_read_i32(loc_2238_[1], loc_2246_, 20);
									if not (rt_equal_i32(loc_2245_, 0)) then
										rt_store_i32(loc_2238_, loc_2241_, 20, loc_2245_)
										rt_store_i32(loc_2238_, loc_2245_, 24, loc_2241_)
									end
								end
							end
						else
							loc_2247_ = loc_2243_;
							loc_2243_ = loc_2244_;
							loc_2244_ = loc_2248_;
							loc_2248_ = loc_2245_;
							loc_2245_ = loc_2241_;
							loc_2247_ = buffer_read_i32(loc_2238_[1], loc_2246_, 8);
							if rt_not_equal_i32(loc_2249_, loc_2247_) then
								loc_2247_, loc_2248_ = loc_2248_, loc_2247_;
								loc_2248_, loc_2249_ = loc_2249_, loc_2248_;
								rt_store_i32(loc_2238_, loc_2248_, 8, loc_2249_)
								rt_store_i32(loc_2238_, loc_2249_, 12, loc_2248_)
							else
								loc_2247_, loc_2248_ = loc_2248_, loc_2247_;
								loc_2249_ = buffer_read_i32(loc_2238_[1], 0, 28636);
								rt_store_i32(loc_2238_, 0, 28636, rt_and_i32(loc_2249_, rt_rotate_left_i32(-2, rt_shift_right_u32(loc_2247_, 3))))
							end
						end
						loc_2246_ = bit32_or(loc_2246_ + loc_2244_, 0);
						loc_2245_ = buffer_read_i32(loc_2238_[1], loc_2246_, 4);
						loc_2244_ = bit32_or(loc_2244_ + loc_2243_, 0);
					end
					rt_store_i32(loc_2238_, loc_2246_, 4, rt_and_i32(loc_2245_, -2))
					rt_store_i32(loc_2238_, bit32_or(loc_2240_ + loc_2244_, 0), 0, loc_2244_)
					rt_store_i32(loc_2238_, loc_2240_, 4, rt_or_i32(loc_2244_, 1))
					if rt_greater_than_u32(loc_2244_, 255) then
						loc_2243_ = 31;
						if not (rt_greater_than_u32(loc_2244_, 16777215)) then
							loc_2245_ = loc_2244_;
							loc_2246_ = loc_2243_;
							loc_2244_ = loc_2245_;
							loc_2246_ = rt_leading_zeroes_i32(rt_shift_right_u32(loc_2245_, 8));
							loc_2243_ = bit32_or(bit32_or(rt_and_i32(rt_shift_right_u32(loc_2245_, bit32_or(38 - loc_2246_, 0)), 1) - rt_shift_left_i32(loc_2246_, 1), 0) + 62, 0);
						end
						rt_store_i32(loc_2238_, loc_2240_, 28, loc_2243_)
						rt_store_i64(loc_2238_, loc_2240_, 16, into_bits_i64(0, 0))
						loc_2246_ = buffer_read_i32(loc_2238_[1], 0, 28640);
						loc_2241_ = bit32_or(rt_shift_left_i32(loc_2243_, 2) + 28940, 0);
						loc_2239_ = rt_shift_left_i32(1, loc_2243_);
						if rt_not_equal_i32(rt_and_i32(loc_2246_, loc_2239_), 0) then
							loc_2246_ = 0;
							loc_2245_ = bit32_or(25 - rt_shift_right_u32(loc_2243_, 1), 0);
							if rt_equal_i32(loc_2243_, 31) then
								loc_2243_ = loc_2244_;
							else
								loc_2243_ = loc_2244_;
								loc_2246_ = loc_2245_;
							end
							loc_2245_ = buffer_read_i32(loc_2238_[1], loc_2241_, 0);
							loc_2244_ = rt_shift_left_i32(loc_2244_, loc_2246_);
							repeat
								rt_yield_budget = rt_yield_budget - 1
								if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
								loc_2246_ = loc_2242_;
								loc_2242_ = loc_2241_;
								loc_2246_ = buffer_read_i32(loc_2238_[1], loc_2245_, 4);
								if rt_equal_i32(rt_and_i32(loc_2246_, -8), loc_2243_) then
									loc_2241_ = loc_2245_;
									loc_2246_ = 0;
									loc_2242_ = 1;
								else
									loc_2241_ = loc_2245_;
									loc_2246_ = loc_2239_;
									loc_2239_ = bit32_or(loc_2241_ + rt_and_i32(rt_shift_right_u32(loc_2244_, 29), 4), 0);
									loc_2245_ = buffer_read_i32(loc_2238_[1], loc_2239_, 16);
									loc_2244_ = rt_shift_left_i32(loc_2244_, 1);
									if rt_not_equal_i32(loc_2245_, 0) then
										loc_2246_ = 1;
										loc_2242_ = 65535;
									else
										loc_2246_ = 0;
										loc_2242_ = 0;
									end
								end
							until loc_2246_ == 0
							if rt_not_equal_i32(loc_2242_, 0) then
								loc_2239_ = buffer_read_i32(loc_2238_[1], loc_2241_, 8);
								rt_store_i32(loc_2238_, loc_2239_, 12, loc_2240_)
								rt_store_i32(loc_2238_, loc_2241_, 8, loc_2240_)
								rt_store_i32(loc_2238_, loc_2240_, 24, 0)
								rt_store_i32(loc_2238_, loc_2240_, 12, loc_2241_)
								rt_store_i32(loc_2238_, loc_2240_, 8, loc_2239_)
							else
								rt_store_i32(loc_2238_, bit32_or(loc_2239_ + 16, 0), 0, loc_2240_)
								rt_store_i32(loc_2238_, loc_2240_, 24, loc_2241_)
								rt_store_i32(loc_2238_, loc_2240_, 12, loc_2240_)
								rt_store_i32(loc_2238_, loc_2240_, 8, loc_2240_)
							end
						else
							loc_2245_ = loc_2242_;
							rt_store_i32(loc_2238_, loc_2241_, 0, loc_2240_)
							rt_store_i32(loc_2238_, 0, 28640, rt_or_i32(loc_2246_, loc_2239_))
							rt_store_i32(loc_2238_, loc_2240_, 24, loc_2241_)
							rt_store_i32(loc_2238_, loc_2240_, 8, loc_2240_)
							rt_store_i32(loc_2238_, loc_2240_, 12, loc_2240_)
						end
					else
						loc_2246_ = loc_2242_;
						loc_2243_ = buffer_read_i32(loc_2238_[1], 0, 28636);
						loc_2245_ = rt_shift_left_i32(1, rt_shift_right_u32(loc_2244_, 3));
						loc_2244_ = bit32_or(rt_and_i32(loc_2244_, -8) + 28676, 0);
						if rt_not_equal_i32(rt_and_i32(loc_2243_, loc_2245_), 0) then
							loc_2246_ = loc_2240_;
							loc_2245_ = buffer_read_i32(loc_2238_[1], loc_2244_, 8);
						else
							loc_2246_ = loc_2240_;
							rt_store_i32(loc_2238_, 0, 28636, rt_or_i32(loc_2243_, loc_2245_))
							loc_2245_ = loc_2244_;
						end
						rt_store_i32(loc_2238_, loc_2245_, 12, loc_2246_)
						rt_store_i32(loc_2238_, loc_2244_, 8, loc_2246_)
						rt_store_i32(loc_2238_, loc_2246_, 12, loc_2244_)
						rt_store_i32(loc_2238_, loc_2246_, 8, loc_2245_)
					end
				else
					loc_2247_ = loc_2243_;
					loc_2248_ = loc_2246_;
					loc_2246_ = loc_2241_;
					loc_2249_ = loc_2242_;
					rt_store_i32(loc_2238_, 0, 28656, loc_2240_)
					loc_2249_ = buffer_read_i32(loc_2238_[1], 0, 28644);
					loc_2249_ = bit32_or(loc_2249_ + loc_2244_, 0);
					rt_store_i32(loc_2238_, 0, 28644, loc_2249_)
					rt_store_i32(loc_2238_, loc_2240_, 4, rt_or_i32(loc_2249_, 1))
					rt_store_i32(loc_2238_, bit32_or(loc_2240_ + loc_2249_, 0), 0, loc_2249_)
				end
			else
				loc_2236_ = loc_2235_;
				loc_2247_ = loc_2243_;
				loc_2248_ = loc_2246_;
				loc_2246_ = loc_2241_;
				loc_2249_ = loc_2242_;
				rt_store_i32(loc_2238_, 0, 28660, loc_2240_)
				loc_2249_ = buffer_read_i32(loc_2238_[1], 0, 28648);
				loc_2249_ = bit32_or(loc_2249_ + loc_2244_, 0);
				rt_store_i32(loc_2238_, 0, 28648, loc_2249_)
				rt_store_i32(loc_2238_, loc_2240_, 4, rt_or_i32(loc_2249_, 1))
			end
			return bit32_or(loc_2237_ + 8, 0), loc_2236_
		end), "i32,i32,i32->i32")
	end)(module_locals[3]);
	module_locals[160] = { nil };
	module_locals[159][1] = (function(loc_2250_)
		return rt_function_type(--[[fn:free]](function(loc_2251_, loc_2252_)
			local loc_2253_
			loc_2253_ = loc_2252_;
			loc_2250_[1](loc_2251_, loc_2253_)
			return loc_2253_
		end), "i32->")
	end)(module_locals[160]);
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[160][1] = (function(loc_2254_)
		return rt_function_type(--[[fn:dlfree]](function(loc_2255_, loc_2256_)
			local loc_2257_, loc_2258_, loc_2259_, loc_2260_, loc_2261_, loc_2262_, loc_2263_, loc_2264_, loc_2265_, loc_2266_, loc_2267_, loc_2268_, loc_2269_
			loc_2259_ = 0;
			loc_2261_ = 0;
			loc_2262_ = 0;
			if rt_equal_i32(loc_2255_, 0) then
				loc_2257_ = loc_2256_;
				loc_2258_ = loc_2254_;
				loc_2260_ = loc_2255_;
				loc_2259_ = 0;
			else
				loc_2257_ = loc_2256_;
				loc_2258_ = loc_2254_;
				loc_2260_ = loc_2255_;
				loc_2267_ = loc_2261_;
				loc_2269_ = buffer_read_i32(loc_2258_[1], bit32_or(loc_2260_ + -4, 0), 0);
				loc_2261_ = rt_and_i32(loc_2269_, -8);
				loc_2260_ = bit32_or(loc_2260_ + -8, 0);
				loc_2268_ = bit32_or(loc_2260_ + loc_2261_, 0);
				if rt_not_equal_i32(rt_and_i32(loc_2269_, 1), 0) then
					loc_2263_ = loc_2267_;
					loc_2264_ = loc_2262_;
					loc_2262_ = loc_2259_;
					loc_2259_ = loc_2268_;
					loc_2269_ = 0;
				else
					loc_2263_ = loc_2267_;
					loc_2264_ = loc_2262_;
					loc_2262_ = loc_2259_;
					loc_2259_ = loc_2268_;
					if rt_equal_i32(rt_and_i32(loc_2269_, 2), 0) then
						loc_2269_ = 1;
					else
						loc_2269_ = buffer_read_i32(loc_2258_[1], loc_2260_, 0);
						loc_2268_ = buffer_read_i32(loc_2258_[1], 0, 28652);
						loc_2260_ = bit32_or(loc_2260_ - loc_2269_, 0);
						if rt_less_than_u32(loc_2260_, loc_2268_) then
							loc_2269_ = 2;
						else
							loc_2268_ = buffer_read_i32(loc_2258_[1], 0, 28656);
							loc_2261_ = bit32_or(loc_2269_ + loc_2261_, 0);
							if rt_equal_i32(loc_2260_, loc_2268_) then
								loc_2269_ = buffer_read_i32(loc_2258_[1], loc_2259_, 4);
								if rt_not_equal_i32(rt_and_i32(loc_2269_, 3), 3) then
									loc_2269_ = 0;
								else
									rt_store_i32(loc_2258_, loc_2259_, 4, rt_and_i32(loc_2269_, -2))
									rt_store_i32(loc_2258_, 0, 28644, loc_2261_)
									rt_store_i32(loc_2258_, loc_2259_, 0, loc_2261_)
									rt_store_i32(loc_2258_, loc_2260_, 4, rt_or_i32(loc_2261_, 1))
									loc_2269_ = 3;
								end
							else
								loc_2268_ = loc_2269_;
								loc_2269_ = buffer_read_i32(loc_2258_[1], loc_2260_, 12);
								if rt_greater_than_u32(loc_2268_, 255) then
									loc_2268_ = buffer_read_i32(loc_2258_[1], loc_2260_, 24);
									if rt_equal_i32(loc_2269_, loc_2260_) then
										loc_2267_ = buffer_read_i32(loc_2258_[1], loc_2260_, 20);
										if rt_equal_i32(loc_2267_, 0) then
											loc_2267_ = buffer_read_i32(loc_2258_[1], loc_2260_, 16);
											if rt_equal_i32(loc_2267_, 0) then
												loc_2266_ = 1;
												loc_2269_ = 0;
											else
												loc_2265_ = loc_2260_;
												loc_2266_ = loc_2263_;
												loc_2266_ = 0;
												loc_2260_ = loc_2265_;
												loc_2263_ = bit32_or(loc_2265_ + 16, 0);
											end
										else
											loc_2265_ = loc_2260_;
											loc_2266_ = loc_2263_;
											loc_2266_ = 0;
											loc_2260_ = loc_2265_;
											loc_2263_ = bit32_or(loc_2265_ + 20, 0);
										end
										if not (rt_not_equal_i32(loc_2266_, 0)) then
											repeat
												rt_yield_budget = rt_yield_budget - 1
												if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
												loc_2265_ = loc_2264_;
												loc_2266_ = loc_2263_;
												loc_2269_ = buffer_read_i32(loc_2258_[1], loc_2267_, 20);
												loc_2263_ = bit32_or(loc_2267_ + 20, 0);
												if rt_not_equal_i32(loc_2269_, 0) then
													loc_2264_ = loc_2266_;
													loc_2266_ = loc_2262_;
													loc_2267_, loc_2269_ = loc_2269_, loc_2267_;
													loc_2266_ = 1;
													loc_2262_ = 65535;
												else
													loc_2264_ = loc_2266_;
													loc_2265_ = loc_2263_;
													loc_2266_ = loc_2262_;
													loc_2267_, loc_2269_ = loc_2269_, loc_2267_;
													loc_2267_ = buffer_read_i32(loc_2258_[1], loc_2269_, 16);
													loc_2263_ = bit32_or(loc_2269_ + 16, 0);
													if rt_not_equal_i32(loc_2267_, 0) then
														loc_2266_ = 1;
														loc_2262_ = 65535;
													else
														loc_2265_ = loc_2266_;
														loc_2266_ = 0;
														loc_2262_ = loc_2265_;
													end
												end
											until loc_2266_ == 0
											rt_store_i32(loc_2258_, loc_2264_, 0, 0)
										end
									else
										loc_2267_ = buffer_read_i32(loc_2258_[1], loc_2260_, 8);
										rt_store_i32(loc_2258_, loc_2267_, 12, loc_2269_)
										rt_store_i32(loc_2258_, loc_2269_, 8, loc_2267_)
									end
									if rt_equal_i32(loc_2268_, 0) then
										loc_2269_ = 0;
									else
										loc_2267_ = loc_2263_;
										loc_2263_ = buffer_read_i32(loc_2258_[1], loc_2260_, 28);
										loc_2267_ = rt_shift_left_i32(loc_2263_, 2);
										loc_2266_ = buffer_read_i32(loc_2258_[1], loc_2267_, 28940);
										if rt_not_equal_i32(loc_2260_, loc_2266_) then
											loc_2267_ = buffer_read_i32(loc_2258_[1], loc_2268_, 16);
											if rt_not_equal_i32(loc_2267_, loc_2260_) then
												rt_store_i32(loc_2258_, loc_2268_, 20, loc_2269_)
											else
												rt_store_i32(loc_2258_, loc_2268_, 16, loc_2269_)
											end
											if rt_equal_i32(loc_2269_, 0) then
												loc_2267_ = 2;
											else
												loc_2267_ = 0;
											end
										else
											rt_store_i32(loc_2258_, bit32_or(loc_2267_ + 28940, 0), 0, loc_2269_)
											if rt_not_equal_i32(loc_2269_, 0) then
												loc_2267_ = 0;
											else
												loc_2267_ = buffer_read_i32(loc_2258_[1], 0, 28640);
												rt_store_i32(loc_2258_, 0, 28640, rt_and_i32(loc_2267_, rt_rotate_left_i32(-2, loc_2263_)))
												loc_2267_ = 1;
											end
										end
										if (loc_2267_) >= 0 and (loc_2267_) < 2 then
											if (loc_2267_) < 1 then
												rt_store_i32(loc_2258_, loc_2269_, 24, loc_2268_)
												loc_2268_ = buffer_read_i32(loc_2258_[1], loc_2260_, 16);
												if not (rt_equal_i32(loc_2268_, 0)) then
													rt_store_i32(loc_2258_, loc_2269_, 16, loc_2268_)
													rt_store_i32(loc_2258_, loc_2268_, 24, loc_2269_)
												end
												loc_2268_ = buffer_read_i32(loc_2258_[1], loc_2260_, 20);
												if rt_equal_i32(loc_2268_, 0) then
													loc_2269_ = 0;
												else
													rt_store_i32(loc_2258_, loc_2269_, 20, loc_2268_)
													rt_store_i32(loc_2258_, loc_2268_, 24, loc_2269_)
													loc_2269_ = 0;
												end
											else
												loc_2269_ = 0;
											end
										else
											loc_2269_ = 0;
										end
									end
								else
									loc_2267_ = loc_2263_;
									loc_2263_ = buffer_read_i32(loc_2258_[1], loc_2260_, 8);
									if rt_not_equal_i32(loc_2269_, loc_2263_) then
										rt_store_i32(loc_2258_, loc_2269_, 8, loc_2263_)
										rt_store_i32(loc_2258_, loc_2263_, 12, loc_2269_)
										loc_2269_ = 0;
									else
										loc_2269_ = buffer_read_i32(loc_2258_[1], 0, 28636);
										rt_store_i32(loc_2258_, 0, 28636, rt_and_i32(loc_2269_, rt_rotate_left_i32(-2, rt_shift_right_u32(loc_2268_, 3))))
										loc_2269_ = 0;
									end
								end
							end
						end
					end
				end
				if (loc_2269_) >= 0 and (loc_2269_) < 3 then
					if (loc_2269_) < 1 then
						if rt_greater_than_equal_u32(loc_2260_, loc_2259_) then
							loc_2259_, loc_2264_ = loc_2264_, loc_2259_;
							loc_2264_, loc_2262_ = loc_2262_, loc_2264_;
							loc_2262_, loc_2260_ = loc_2260_, loc_2262_;
							loc_2260_, loc_2263_ = loc_2263_, loc_2260_;
							loc_2263_, loc_2261_ = loc_2261_, loc_2263_;
							loc_2259_ = 0;
						else
							loc_2269_ = loc_2263_;
							loc_2263_ = loc_2261_;
							loc_2261_ = loc_2259_;
							loc_2259_ = loc_2264_;
							loc_2264_ = loc_2262_;
							loc_2262_ = loc_2260_;
							loc_2260_ = buffer_read_i32(loc_2258_[1], loc_2261_, 4);
							if rt_equal_i32(rt_and_i32(loc_2260_, 1), 0) then
								loc_2265_ = loc_2259_;
								loc_2259_ = loc_2269_;
								loc_2259_ = 0;
							else
								loc_2265_ = loc_2259_;
								loc_2259_ = loc_2269_;
								if rt_not_equal_i32(rt_and_i32(loc_2260_, 2), 0) then
									loc_2266_ = loc_2261_;
									loc_2261_ = loc_2265_;
									loc_2265_ = loc_2264_;
									loc_2264_ = loc_2263_;
									loc_2263_ = loc_2262_;
									loc_2262_ = loc_2259_;
									loc_2267_ = loc_2260_;
									rt_store_i32(loc_2258_, loc_2266_, 4, rt_and_i32(loc_2267_, -2))
									rt_store_i32(loc_2258_, bit32_or(loc_2263_ + loc_2264_, 0), 0, loc_2264_)
									rt_store_i32(loc_2258_, loc_2263_, 4, rt_or_i32(loc_2264_, 1))
									loc_2267_ = 0;
								else
									loc_2266_ = loc_2261_;
									loc_2261_ = loc_2265_;
									loc_2265_ = loc_2264_;
									loc_2264_ = loc_2263_;
									loc_2263_ = loc_2262_;
									loc_2262_ = loc_2259_;
									loc_2267_ = loc_2260_;
									loc_2269_ = buffer_read_i32(loc_2258_[1], 0, 28660);
									if rt_not_equal_i32(loc_2266_, loc_2269_) then
										loc_2259_ = loc_2261_;
										loc_2260_ = loc_2262_;
										loc_2262_ = loc_2266_;
										loc_2266_ = loc_2264_;
										loc_2268_ = loc_2267_;
										loc_2267_ = buffer_read_i32(loc_2258_[1], 0, 28656);
										if rt_not_equal_i32(loc_2262_, loc_2267_) then
											loc_2269_ = buffer_read_i32(loc_2258_[1], loc_2262_, 12);
											loc_2264_ = bit32_or(rt_and_i32(loc_2268_, -8) + loc_2266_, 0);
											if rt_greater_than_u32(loc_2268_, 255) then
												loc_2261_ = buffer_read_i32(loc_2258_[1], loc_2262_, 24);
												if rt_equal_i32(loc_2269_, loc_2262_) then
													loc_2268_ = buffer_read_i32(loc_2258_[1], loc_2262_, 20);
													if rt_equal_i32(loc_2268_, 0) then
														loc_2268_ = buffer_read_i32(loc_2258_[1], loc_2262_, 16);
														if rt_equal_i32(loc_2268_, 0) then
															loc_2269_ = 1;
															loc_2266_ = 0;
														else
															loc_2266_ = loc_2269_;
															loc_2269_ = loc_2260_;
															loc_2260_ = loc_2262_;
															loc_2269_ = 0;
															loc_2262_ = loc_2260_;
															loc_2260_ = bit32_or(loc_2260_ + 16, 0);
														end
													else
														loc_2266_ = loc_2269_;
														loc_2269_ = loc_2260_;
														loc_2260_ = loc_2262_;
														loc_2269_ = 0;
														loc_2262_ = loc_2260_;
														loc_2260_ = bit32_or(loc_2260_ + 20, 0);
													end
													if not (rt_not_equal_i32(loc_2269_, 0)) then
														loc_2269_ = loc_2259_;
														loc_2260_, loc_2268_ = loc_2268_, loc_2260_;
														loc_2259_ = loc_2268_;
														loc_2268_ = loc_2269_;
														repeat
															rt_yield_budget = rt_yield_budget - 1
															if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
															loc_2269_ = loc_2266_;
															loc_2266_ = loc_2268_;
															loc_2268_ = loc_2259_;
															loc_2269_ = buffer_read_i32(loc_2258_[1], loc_2260_, 20);
															loc_2259_ = bit32_or(loc_2260_ + 20, 0);
															if rt_not_equal_i32(loc_2269_, 0) then
																loc_2266_ = loc_2260_;
																loc_2260_ = loc_2269_;
																loc_2269_ = loc_2265_;
																loc_2269_ = 1;
																loc_2265_ = 65535;
															else
																loc_2266_ = loc_2260_;
																loc_2260_ = loc_2259_;
																loc_2265_, loc_2269_ = loc_2269_, loc_2265_;
																loc_2260_ = buffer_read_i32(loc_2258_[1], loc_2266_, 16);
																loc_2259_ = bit32_or(loc_2266_ + 16, 0);
																if rt_not_equal_i32(loc_2260_, 0) then
																	loc_2269_ = 1;
																	loc_2265_ = 65535;
																else
																	loc_2265_ = loc_2269_;
																	loc_2269_ = 0;
																end
															end
														until loc_2269_ == 0
														rt_store_i32(loc_2258_, loc_2268_, 0, 0)
													end
												else
													loc_2266_ = loc_2259_;
													loc_2268_ = loc_2260_;
													loc_2268_ = buffer_read_i32(loc_2258_[1], loc_2262_, 8);
													rt_store_i32(loc_2258_, loc_2268_, 12, loc_2269_)
													rt_store_i32(loc_2258_, loc_2269_, 8, loc_2268_)
													loc_2266_ = loc_2269_;
												end
												if not (rt_equal_i32(loc_2261_, 0)) then
													loc_2259_ = buffer_read_i32(loc_2258_[1], loc_2262_, 28);
													loc_2260_ = rt_shift_left_i32(loc_2259_, 2);
													loc_2268_ = buffer_read_i32(loc_2258_[1], loc_2260_, 28940);
													if rt_not_equal_i32(loc_2262_, loc_2268_) then
														loc_2260_ = buffer_read_i32(loc_2258_[1], loc_2261_, 16);
														if rt_not_equal_i32(loc_2260_, loc_2262_) then
															rt_store_i32(loc_2258_, loc_2261_, 20, loc_2266_)
														else
															rt_store_i32(loc_2258_, loc_2261_, 16, loc_2266_)
														end
														if rt_equal_i32(loc_2266_, 0) then
															loc_2260_ = 1;
														else
															loc_2260_ = 0;
														end
													else
														rt_store_i32(loc_2258_, bit32_or(loc_2260_ + 28940, 0), 0, loc_2266_)
														if rt_not_equal_i32(loc_2266_, 0) then
															loc_2260_ = loc_2259_;
															loc_2260_ = 0;
														else
															loc_2260_ = loc_2259_;
															loc_2259_ = buffer_read_i32(loc_2258_[1], 0, 28640);
															rt_store_i32(loc_2258_, 0, 28640, rt_and_i32(loc_2259_, rt_rotate_left_i32(-2, loc_2260_)))
															loc_2260_ = 1;
														end
													end
													if not (rt_not_equal_i32(loc_2260_, 0)) then
														rt_store_i32(loc_2258_, loc_2266_, 24, loc_2261_)
														loc_2261_ = buffer_read_i32(loc_2258_[1], loc_2262_, 16);
														if not (rt_equal_i32(loc_2261_, 0)) then
															rt_store_i32(loc_2258_, loc_2266_, 16, loc_2261_)
															rt_store_i32(loc_2258_, loc_2261_, 24, loc_2266_)
														end
														loc_2262_ = buffer_read_i32(loc_2258_[1], loc_2262_, 20);
														if not (rt_equal_i32(loc_2262_, 0)) then
															rt_store_i32(loc_2258_, loc_2266_, 20, loc_2262_)
															rt_store_i32(loc_2258_, loc_2262_, 24, loc_2266_)
														end
													end
												end
											else
												loc_2261_ = loc_2259_;
												loc_2266_ = loc_2260_;
												loc_2266_ = buffer_read_i32(loc_2258_[1], loc_2262_, 8);
												if rt_not_equal_i32(loc_2269_, loc_2266_) then
													loc_2266_, loc_2268_ = loc_2268_, loc_2266_;
													loc_2268_, loc_2269_ = loc_2269_, loc_2268_;
													rt_store_i32(loc_2258_, loc_2268_, 8, loc_2269_)
													rt_store_i32(loc_2258_, loc_2269_, 12, loc_2268_)
												else
													loc_2266_, loc_2268_ = loc_2268_, loc_2266_;
													loc_2269_ = buffer_read_i32(loc_2258_[1], 0, 28636);
													rt_store_i32(loc_2258_, 0, 28636, rt_and_i32(loc_2269_, rt_rotate_left_i32(-2, rt_shift_right_u32(loc_2266_, 3))))
												end
											end
											rt_store_i32(loc_2258_, bit32_or(loc_2263_ + loc_2264_, 0), 0, loc_2264_)
											rt_store_i32(loc_2258_, loc_2263_, 4, rt_or_i32(loc_2264_, 1))
											if rt_not_equal_i32(loc_2263_, loc_2267_) then
												loc_2267_ = 0;
											else
												rt_store_i32(loc_2258_, 0, 28644, loc_2264_)
												loc_2267_ = 4;
											end
										else
											loc_2264_ = loc_2267_;
											loc_2267_ = loc_2260_;
											loc_2269_ = loc_2262_;
											loc_2262_ = loc_2259_;
											rt_store_i32(loc_2258_, 0, 28656, loc_2263_)
											loc_2269_ = buffer_read_i32(loc_2258_[1], 0, 28644);
											loc_2264_ = bit32_or(loc_2269_ + loc_2266_, 0);
											rt_store_i32(loc_2258_, 0, 28644, loc_2264_)
											rt_store_i32(loc_2258_, loc_2263_, 4, rt_or_i32(loc_2264_, 1))
											rt_store_i32(loc_2258_, bit32_or(loc_2263_ + loc_2264_, 0), 0, loc_2264_)
											loc_2267_ = 3;
										end
									else
										loc_2268_ = loc_2267_;
										loc_2267_ = loc_2262_;
										loc_2269_ = loc_2266_;
										loc_2266_ = loc_2264_;
										loc_2264_ = loc_2261_;
										rt_store_i32(loc_2258_, 0, 28660, loc_2263_)
										loc_2269_ = buffer_read_i32(loc_2258_[1], 0, 28648);
										loc_2264_ = bit32_or(loc_2269_ + loc_2266_, 0);
										rt_store_i32(loc_2258_, 0, 28648, loc_2264_)
										rt_store_i32(loc_2258_, loc_2263_, 4, rt_or_i32(loc_2264_, 1))
										loc_2269_ = buffer_read_i32(loc_2258_[1], 0, 28656);
										if rt_not_equal_i32(loc_2263_, loc_2269_) then
											loc_2267_ = 1;
										else
											rt_store_i32(loc_2258_, 0, 28644, 0)
											rt_store_i32(loc_2258_, 0, 28656, 0)
											loc_2267_ = 2;
										end
									end
								end
								if (loc_2267_) >= 0 and (loc_2267_) < 4 then
									if (loc_2267_) < 2 then
										if (loc_2267_) < 1 then
											if rt_greater_than_u32(loc_2264_, 255) then
												loc_2260_ = loc_2264_;
												loc_2264_ = loc_2263_;
												loc_2263_ = loc_2265_;
												loc_2261_ = 31;
												if not (rt_greater_than_u32(loc_2260_, 16777215)) then
													loc_2266_ = loc_2260_;
													loc_2267_ = loc_2261_;
													loc_2260_ = loc_2266_;
													loc_2267_ = rt_leading_zeroes_i32(rt_shift_right_u32(loc_2266_, 8));
													loc_2261_ = bit32_or(bit32_or(rt_and_i32(rt_shift_right_u32(loc_2266_, bit32_or(38 - loc_2267_, 0)), 1) - rt_shift_left_i32(loc_2267_, 1), 0) + 62, 0);
												end
												rt_store_i32(loc_2258_, loc_2264_, 28, loc_2261_)
												rt_store_i64(loc_2258_, loc_2264_, 16, into_bits_i64(0, 0))
												loc_2262_ = buffer_read_i32(loc_2258_[1], 0, 28640);
												loc_2265_ = rt_shift_left_i32(1, loc_2261_);
												loc_2259_ = bit32_or(rt_shift_left_i32(loc_2261_, 2) + 28940, 0);
												if rt_not_equal_i32(rt_and_i32(loc_2262_, loc_2265_), 0) then
													loc_2266_ = 0;
													loc_2267_ = bit32_or(25 - rt_shift_right_u32(loc_2261_, 1), 0);
													if rt_equal_i32(loc_2261_, 31) then
														loc_2261_ = loc_2260_;
													else
														loc_2261_ = loc_2260_;
														loc_2266_ = loc_2267_;
													end
													loc_2259_ = buffer_read_i32(loc_2258_[1], loc_2259_, 0);
													loc_2260_ = rt_shift_left_i32(loc_2260_, loc_2266_);
													repeat
														rt_yield_budget = rt_yield_budget - 1
														if rt_yield_budget < 0 then rt_yield_budget = rt_yield_point() end
														loc_2266_ = loc_2263_;
														loc_2263_ = loc_2262_;
														loc_2266_ = buffer_read_i32(loc_2258_[1], loc_2259_, 4);
														if rt_equal_i32(rt_and_i32(loc_2266_, -8), loc_2261_) then
															loc_2262_ = loc_2259_;
															loc_2266_ = 0;
															loc_2263_ = 1;
														else
															loc_2262_ = loc_2259_;
															loc_2266_ = loc_2265_;
															loc_2265_ = loc_2259_;
															loc_2265_ = bit32_or(loc_2262_ + rt_and_i32(rt_shift_right_u32(loc_2260_, 29), 4), 0);
															loc_2259_ = buffer_read_i32(loc_2258_[1], loc_2265_, 16);
															loc_2260_ = rt_shift_left_i32(loc_2260_, 1);
															if rt_not_equal_i32(loc_2259_, 0) then
																loc_2266_ = 1;
																loc_2263_ = 65535;
															else
																loc_2266_ = 0;
																loc_2263_ = 0;
															end
														end
													until loc_2266_ == 0
													if rt_not_equal_i32(loc_2263_, 0) then
														loc_2261_ = buffer_read_i32(loc_2258_[1], loc_2262_, 8);
														rt_store_i32(loc_2258_, loc_2261_, 12, loc_2264_)
														rt_store_i32(loc_2258_, loc_2262_, 8, loc_2264_)
														loc_2259_ = 1;
														loc_2263_ = 24;
														loc_2260_ = 8;
														loc_2265_ = 0;
													else
														loc_2261_ = loc_2262_;
														rt_store_i32(loc_2258_, bit32_or(loc_2265_ + 16, 0), 0, loc_2264_)
														loc_2259_ = 0;
														loc_2263_ = 8;
														loc_2260_ = 24;
														loc_2262_ = loc_2261_;
													end
												else
													loc_2266_ = loc_2263_;
													loc_2263_ = loc_2260_;
													loc_2267_ = loc_2259_;
													rt_store_i32(loc_2258_, loc_2267_, 0, loc_2264_)
													rt_store_i32(loc_2258_, 0, 28640, rt_or_i32(loc_2262_, loc_2265_))
													loc_2259_ = 0;
													loc_2263_ = 8;
													loc_2260_ = 24;
													loc_2261_ = loc_2267_;
												end
												if not (rt_not_equal_i32(loc_2259_, 0)) then
													loc_2262_, loc_2264_ = loc_2264_, loc_2262_;
													loc_2264_ = loc_2262_;
													loc_2265_ = loc_2262_;
												end
												rt_store_i32(loc_2258_, bit32_or(loc_2264_ + loc_2260_, 0), 0, loc_2261_)
												rt_store_i32(loc_2258_, loc_2264_, 12, loc_2262_)
												rt_store_i32(loc_2258_, bit32_or(loc_2264_ + loc_2263_, 0), 0, loc_2265_)
												loc_2265_ = buffer_read_i32(loc_2258_[1], 0, 28668);
												loc_2264_ = 0;
												loc_2265_ = bit32_or(loc_2265_ + -1, 0);
												loc_2263_ = -1;
												if not (rt_not_equal_i32(loc_2265_, 0)) then
													loc_2265_ = loc_2263_;
												end
												rt_store_i32(loc_2258_, loc_2264_, 28668, loc_2265_)
												loc_2259_ = 0;
											else
												loc_2260_ = loc_2264_;
												loc_2264_ = loc_2263_;
												loc_2267_ = loc_2265_;
												loc_2267_ = buffer_read_i32(loc_2258_[1], 0, 28636);
												loc_2266_ = rt_shift_left_i32(1, rt_shift_right_u32(loc_2260_, 3));
												loc_2265_ = bit32_or(rt_and_i32(loc_2260_, -8) + 28676, 0);
												if rt_not_equal_i32(rt_and_i32(loc_2267_, loc_2266_), 0) then
													loc_2264_, loc_2267_ = loc_2267_, loc_2264_;
													loc_2266_ = buffer_read_i32(loc_2258_[1], loc_2265_, 8);
												else
													loc_2264_, loc_2267_ = loc_2267_, loc_2264_;
													rt_store_i32(loc_2258_, 0, 28636, rt_or_i32(loc_2264_, loc_2266_))
													loc_2266_ = loc_2265_;
												end
												rt_store_i32(loc_2258_, loc_2266_, 12, loc_2267_)
												rt_store_i32(loc_2258_, loc_2265_, 8, loc_2267_)
												rt_store_i32(loc_2258_, loc_2267_, 12, loc_2265_)
												rt_store_i32(loc_2258_, loc_2267_, 8, loc_2266_)
												loc_2259_ = 1;
											end
										else
											loc_2259_ = 0;
										end
									elseif (loc_2267_) > 2 then
										loc_2259_ = 1;
									else
										loc_2259_ = 1;
									end
								else
									loc_2259_ = 1;
								end
							end
						end
					elseif (loc_2269_) > 1 then
						loc_2259_, loc_2264_ = loc_2264_, loc_2259_;
						loc_2264_, loc_2262_ = loc_2262_, loc_2264_;
						loc_2262_, loc_2260_ = loc_2260_, loc_2262_;
						loc_2260_, loc_2263_ = loc_2263_, loc_2260_;
						loc_2263_, loc_2261_ = loc_2261_, loc_2263_;
						loc_2259_ = 0;
					else
						loc_2259_, loc_2264_ = loc_2264_, loc_2259_;
						loc_2264_, loc_2262_ = loc_2262_, loc_2264_;
						loc_2262_, loc_2260_ = loc_2260_, loc_2262_;
						loc_2260_, loc_2263_ = loc_2263_, loc_2260_;
						loc_2263_, loc_2261_ = loc_2261_, loc_2263_;
						loc_2259_ = 0;
					end
				else
					loc_2259_ = 1;
				end
			end
			if rt_not_equal_i32(loc_2259_, 0) then
			end
			return loc_2257_
		end), "i32->")
	end)(module_locals[3]);
	end)() end --[[/spider:chunk]]
	do (function() --[[spider:chunk]]
	module_locals[161][1] = (function(loc_2270_, loc_2271_)
		return rt_function_type(--[[fn:calloc]](function(loc_2272_, loc_2273_, loc_2274_)
			local loc_2275_, loc_2276_, loc_2277_, loc_2278_, loc_2279_, loc_2280_, loc_2281_
			if rt_not_equal_i32(loc_2272_, 0) then
				loc_2275_ = loc_2273_;
				loc_2277_ = loc_2271_;
				loc_2278_ = loc_2270_;
				loc_2280_ = loc_2274_;
				loc_2281_ = loc_2272_;
				loc_2276_ = rt_multiply_i64(rt_widen_i32(loc_2281_), rt_widen_i32(loc_2275_));
				loc_2279_ = rt_narrow_i64(loc_2276_);
				if not (rt_less_than_u32(rt_or_i32(loc_2275_, loc_2281_), 65536)) then
					loc_2275_ = loc_2279_;
					loc_2279_ = -1;
					if rt_not_equal_i32(rt_low_shift_right_u64(loc_2276_, 32), 0) then
						loc_2276_ = loc_2275_;
					else
						loc_2276_ = loc_2275_;
						loc_2279_ = loc_2276_;
					end
				end
			else
				loc_2277_ = loc_2271_;
				loc_2278_ = loc_2270_;
				loc_2279_ = loc_2273_;
				loc_2280_ = loc_2274_;
				loc_2281_ = loc_2272_;
				loc_2279_ = 0;
			end
			loc_2276_ = loc_2278_[1](loc_2279_, loc_2280_)
			if not (rt_equal_i32(loc_2276_, 0)) then
				loc_2280_ = rt_load_i32_from_u8(loc_2277_, bit32_or(loc_2276_ + -4, 0), 0);
				if not (rt_equal_i32(rt_and_i32(loc_2280_, 3), 0)) then
					if not (rt_equal_i32(loc_2279_, 0)) then
						rt_memory_fill(loc_2277_, loc_2276_, 0, loc_2279_)
					end
				end
			end
			return loc_2276_, loc_2275_
		end), "i32,i32->i32")
	end)(module_locals[157], module_locals[3]);
	module_locals[166] = rt_table_new({ }, 13, 13);
	rt_table_set(module_locals[166], 0, module_locals[65][1]);
	rt_table_set(module_locals[166], 1, module_locals[67][1]);
	rt_table_set(module_locals[166], 2, module_locals[68][1]);
	rt_table_set(module_locals[166], 3, module_locals[69][1]);
	rt_table_set(module_locals[166], 4, module_locals[70][1]);
	rt_table_set(module_locals[166], 5, module_locals[71][1]);
	rt_table_set(module_locals[166], 6, module_locals[103][1]);
	rt_table_set(module_locals[166], 7, module_locals[105][1]);
	rt_table_set(module_locals[166], 8, module_locals[108][1]);
	rt_table_set(module_locals[166], 9, module_locals[109][1]);
	rt_table_set(module_locals[166], 10, module_locals[128][1]);
	rt_table_set(module_locals[166], 11, module_locals[130][1]);
	rt_table_set(module_locals[166], 12, module_locals[135][1]);
	rt_table_copy(module_locals[162], (function(loc_2282_)
		local loc_2283_
		loc_2283_ = loc_2282_;
		return 1, loc_2283_
	end)(), module_locals[166], 0, 13)
	module_locals[167] = rt_memory_new({ [0] = "softmax\x00-+   0X0x\x00-0X+0X 0X-0x+0x 0x\x00logits\x00/kernels\x00%s%s%s%s\x00%s/%s\x00attention\x00smollm: host kernels on\x00smollm: kernel profile on\x00/tokenizer.bin\x00/model_q8.bin\x00nan\x00rmsnorm\x00silu_mul\x00inf\x00quantize\x00rope\x00embed\x00rb\x00rwa\x00NAN\x00INF\x00logits_q.i8\x00ffn_q.i8\x00quantize_q.i8\x00matvec_q.i8\x00meta.i32\x00attn_v.f32\x00softmax_out.f32\x00silu_out.f32\x00logits_out.f32\x00rope_q_out.f32\x00attn_out.f32\x00rmsnorm_out.f32\x00rope_k_out.f32\x00embed_out.f32\x00matvec_out.f32\x00matvec_w1_out.f32\x00logits_s.f32\x00ffn_s.f32\x00quantize_s.f32\x00matvec_s.f32\x00attn_q.f32\x00softmax_in.f32\x00rope_q_in.f32\x00rmsnorm_in.f32\x00rope_k_in.f32\x00quantize_in.f32\x00attn_k.f32\x00silu_in2.f32\x00silu_in1.f32\x00.\x00quantize(s)\x00matvec_q8(wq)\x00quantize(q)\x00rope(q)\x00(null)\x00rope(k)\x00 (stopped)\x00matvec_q8(w1)\x00smollm: model dim %d hidden %d layers %d heads %d/%d vocab %d seq %d gs %d, loaded in %d ms\n\x00smollm: prefill %d tokens in %d ms (%.1f ms/token), ctx %d%s\n\x00smollm: kernel selftest: %d kernel(s) differ\n\x00smollm: generated %d tokens in %d ms (%.2f tok/s), ctx %d/%d\n\x00smollm: prefill batch %d\n\x00smollm: tokenizer load failed %d\n\x00smollm: model load failed %d\n\x00smollm: kernel %s OK\n\x00\n<|\xd1\x8e\xd0\xb7\xd0\xb5\xd1\x80\xd0\xb7\xd0\xb0\xd0\xba\xd0\xbe\xd0\xbd\xd1\x87\xd0\xb8\xd0\xbb|>\n<|\xd1\x8f_\xd0\xbd\xd0\xb0\xd1\x87\xd0\xb0\xd0\xbb|>\n\x00<|\xd1\x8e\xd0\xb7\xd0\xb5\xd1\x80|>\n\x00Support for formatting long double values is currently disabled.\nTo enable it, add -lc-printscan-long-double to the link command.\n\x00smollm: kernel %s DIFF (%ld bytes differ, first at %ld)\n\x00\x00\x00\x00\x00\x00\x00\x00A\x00\x00\x00Z\x00\x00\x00a\x00\x00\x00z\x00\x00\x00\xaa\x00\x00\x00\xaa\x00\x00\x00\xb5\x00\x00\x00\xb5\x00\x00\x00\xba\x00\x00\x00\xba\x00\x00\x00\xc0\x00\x00\x00\xd6\x00\x00\x00\xd8\x00\x00\x00\xf6\x00\x00\x00\xf8\x00\x00\x00\xc1\x02\x00\x00\xc6\x02\x00\x00\xd1\x02\x00\x00\xe0\x02\x00\x00\xe4\x02\x00\x00\xec\x02\x00\x00\xec\x02\x00\x00\xee\x02\x00\x00\xee\x02\x00\x00p\x03\x00\x00t\x03\x00\x00v\x03\x00\x00w\x03\x00\x00z\x03\x00\x00}\x03\x00\x00\x7f\x03\x00\x00\x7f\x03\x00\x00\x86\x03\x00\x00\x86\x03\x00\x00\x88\x03\x00\x00\x8a\x03\x00\x00\x8c\x03\x00\x00\x8c\x03\x00\x00\x8e\x03\x00\x00\xa1\x03\x00\x00\xa3\x03\x00\x00\xf5\x03\x00\x00\xf7\x03\x00\x00\x81\x04\x00\x00\x8a\x04\x00\x00/\x05\x00\x001\x05\x00\x00V\x05\x00\x00Y\x05\x00\x00Y\x05\x00\x00`\x05\x00\x00\x88\x05\x00\x00\xd0\x05\x00\x00\xea\x05\x00\x00\xef\x05\x00\x00\xf2\x05\x00\x00 \x06\x00\x00J\x06\x00\x00n\x06\x00\x00o\x06\x00\x00q\x06\x00\x00\xd3\x06\x00\x00\xd5\x06\x00\x00\xd5\x06\x00\x00\xe5\x06\x00\x00\xe6\x06\x00\x00\xee\x06\x00\x00\xef\x06\x00\x00\xfa\x06\x00\x00\xfc\x06\x00\x00\xff\x06\x00\x00\xff\x06\x00\x00\x10\x07\x00\x00\x10\x07\x00\x00\x12\x07\x00\x00/\x07\x00\x00M\x07\x00\x00\xa5\x07\x00\x00\xb1\x07\x00\x00\xb1\x07\x00\x00\xca\x07\x00\x00\xea\x07\x00\x00\xf4\x07\x00\x00\xf5\x07\x00\x00\xfa\x07\x00\x00\xfa\x07\x00\x00\x00\x08\x00\x00\x15\x08\x00\x00\x1a\x08\x00\x00\x1a\x08\x00\x00$\x08\x00\x00$\x08\x00\x00(\x08\x00\x00(\x08\x00\x00@\x08\x00\x00X\x08\x00\x00`\x08\x00\x00j\x08\x00\x00\xa0\x08\x00\x00\xb4\x08\x00\x00\xb6\x08\x00\x00\xc7\x08\x00\x00\x04\t\x00\x009\t\x00\x00=\t\x00\x00=\t\x00\x00P\t\x00\x00P\t\x00\x00X\t\x00\x00a\t\x00\x00q\t\x00\x00\x80\t\x00\x00\x85\t\x00\x00\x8c\t\x00\x00\x8f\t\x00\x00\x90\t\x00\x00\x93\t\x00\x00\xa8\t\x00\x00\xaa\t\x00\x00\xb0\t\x00\x00\xb2\t\x00\x00\xb2\t\x00\x00\xb6\t\x00\x00\xb9\t\x00\x00\xbd\t\x00\x00\xbd\t\x00\x00\xce\t\x00\x00\xce\t\x00\x00\xdc\t\x00\x00\xdd\t\x00\x00\xdf\t\x00\x00\xe1\t\x00\x00\xf0\t\x00\x00\xf1\t\x00\x00\xfc\t\x00\x00\xfc\t\x00\x00\x05\n\x00\x00\n\n\x00\x00\x0f\n\x00\x00\x10\n\x00\x00\x13\n\x00\x00(\n\x00\x00*\n\x00\x000\n\x00\x002\n\x00\x003\n\x00\x005\n\x00\x006\n\x00\x008\n\x00\x009\n\x00\x00Y\n\x00\x00\\\n\x00\x00^\n\x00\x00^\n\x00\x00r\n\x00\x00t\n\x00\x00\x85\n\x00\x00\x8d\n\x00\x00\x8f\n\x00\x00\x91\n\x00\x00\x93\n\x00\x00\xa8\n\x00\x00\xaa\n\x00\x00\xb0\n\x00\x00\xb2\n\x00\x00\xb3\n\x00\x00\xb5\n\x00\x00\xb9\n\x00\x00\xbd\n\x00\x00\xbd\n\x00\x00\xd0\n\x00\x00\xd0\n\x00\x00\xe0\n\x00\x00\xe1\n\x00\x00\xf9\n\x00\x00\xf9\n\x00\x00\x05\x0b\x00\x00\x0c\x0b\x00\x00\x0f\x0b\x00\x00\x10\x0b\x00\x00\x13\x0b\x00\x00(\x0b\x00\x00*\x0b\x00\x000\x0b\x00\x002\x0b\x00\x003\x0b\x00\x005\x0b\x00\x009\x0b\x00\x00=\x0b\x00\x00=\x0b\x00\x00\\\x0b\x00\x00]\x0b\x00\x00_\x0b\x00\x00a\x0b\x00\x00q\x0b\x00\x00q\x0b\x00\x00\x83\x0b\x00\x00\x83\x0b\x00\x00\x85\x0b\x00\x00\x8a\x0b\x00\x00\x8e\x0b\x00\x00\x90\x0b\x00\x00\x92\x0b\x00\x00\x95\x0b\x00\x00\x99\x0b\x00\x00\x9a\x0b\x00\x00\x9c\x0b\x00\x00\x9c\x0b\x00\x00\x9e\x0b\x00\x00\x9f\x0b\x00\x00\xa3\x0b\x00\x00\xa4\x0b\x00\x00\xa8\x0b\x00\x00\xaa\x0b\x00\x00\xae\x0b\x00\x00\xb9\x0b\x00\x00\xd0\x0b\x00\x00\xd0\x0b\x00\x00\x05\x0c\x00\x00\x0c\x0c\x00\x00\x0e\x0c\x00\x00\x10\x0c\x00\x00\x12\x0c\x00\x00(\x0c\x00\x00*\x0c\x00\x009\x0c\x00\x00=\x0c\x00\x00=\x0c\x00\x00X\x0c\x00\x00Z\x0c\x00\x00`\x0c\x00\x00a\x0c\x00\x00\x80\x0c\x00\x00\x80\x0c\x00\x00\x85\x0c\x00\x00\x8c\x0c\x00\x00\x8e\x0c\x00\x00\x90\x0c\x00\x00\x92\x0c\x00\x00\xa8\x0c\x00\x00\xaa\x0c\x00\x00\xb3\x0c\x00\x00\xb5\x0c\x00\x00\xb9\x0c\x00\x00\xbd\x0c\x00\x00\xbd\x0c\x00\x00\xde\x0c\x00\x00\xde\x0c\x00\x00\xe0\x0c\x00\x00\xe1\x0c\x00\x00\xf1\x0c\x00\x00\xf2\x0c\x00\x00\x04\r\x00\x00\x0c\r\x00\x00\x0e\r\x00\x00\x10\r\x00\x00\x12\r\x00\x00:\r\x00\x00=\r\x00\x00=\r\x00\x00N\r\x00\x00N\r\x00\x00T\r\x00\x00V\r\x00\x00_\r\x00\x00a\r\x00\x00z\r\x00\x00\x7f\r\x00\x00\x85\r\x00\x00\x96\r\x00\x00\x9a\r\x00\x00\xb1\r\x00\x00\xb3\r\x00\x00\xbb\r\x00\x00\xbd\r\x00\x00\xbd\r\x00\x00\xc0\r\x00\x00\xc6\r\x00\x00\x01\x0e\x00\x000\x0e\x00\x002\x0e\x00\x003\x0e\x00\x00@\x0e\x00\x00F\x0e\x00\x00\x81\x0e\x00\x00\x82\x0e\x00\x00\x84\x0e\x00\x00\x84\x0e\x00\x00\x86\x0e\x00\x00\x8a\x0e\x00\x00\x8c\x0e\x00\x00\xa3\x0e\x00\x00\xa5\x0e\x00\x00\xa5\x0e\x00\x00\xa7\x0e\x00\x00\xb0\x0e\x00\x00\xb2\x0e\x00\x00\xb3\x0e\x00\x00\xbd\x0e\x00\x00\xbd\x0e\x00\x00\xc0\x0e\x00\x00\xc4\x0e\x00\x00\xc6\x0e\x00\x00\xc6\x0e\x00\x00\xdc\x0e\x00\x00\xdf\x0e\x00\x00\x00\x0f\x00\x00\x00\x0f\x00\x00@\x0f\x00\x00G\x0f\x00\x00I\x0f\x00\x00l\x0f\x00\x00\x88\x0f\x00\x00\x8c\x0f\x00\x00\x00\x10\x00\x00*\x10\x00\x00?\x10\x00\x00?\x10\x00\x00P\x10\x00\x00U\x10\x00\x00Z\x10\x00\x00]\x10\x00\x00a\x10\x00\x00a\x10\x00\x00e\x10\x00\x00f\x10\x00\x00n\x10\x00\x00p\x10\x00\x00u\x10\x00\x00\x81\x10\x00\x00\x8e\x10\x00\x00\x8e\x10\x00\x00\xa0\x10\x00\x00\xc5\x10\x00\x00\xc7\x10\x00\x00\xc7\x10\x00\x00\xcd\x10\x00\x00\xcd\x10\x00\x00\xd0\x10\x00\x00\xfa\x10\x00\x00\xfc\x10\x00\x00H\x12\x00\x00J\x12\x00\x00M\x12\x00\x00P\x12\x00\x00V\x12\x00\x00X\x12\x00\x00X\x12\x00\x00Z\x12\x00\x00]\x12\x00\x00`\x12\x00\x00\x88\x12\x00\x00\x8a\x12\x00\x00\x8d\x12\x00\x00\x90\x12\x00\x00\xb0\x12\x00\x00\xb2\x12\x00\x00\xb5\x12\x00\x00\xb8\x12\x00\x00\xbe\x12\x00\x00\xc0\x12\x00\x00\xc0\x12\x00\x00\xc2\x12\x00\x00\xc5\x12\x00\x00\xc8\x12\x00\x00\xd6\x12\x00\x00\xd8\x12\x00\x00\x10\x13\x00\x00\x12\x13\x00\x00\x15\x13\x00\x00\x18\x13\x00\x00Z\x13\x00\x00\x80\x13\x00\x00\x8f\x13\x00\x00\xa0\x13\x00\x00\xf5\x13\x00\x00\xf8\x13\x00\x00\xfd\x13\x00\x00\x01\x14\x00\x00l\x16\x00\x00o\x16\x00\x00\x7f\x16\x00\x00\x81\x16\x00\x00\x9a\x16\x00\x00\xa0\x16\x00\x00\xea\x16\x00\x00\xf1\x16\x00\x00\xf8\x16\x00\x00\x00\x17\x00\x00\x0c\x17\x00\x00\x0e\x17\x00\x00\x11\x17\x00\x00 \x17\x00\x001\x17\x00\x00@\x17\x00\x00Q\x17\x00\x00`\x17\x00\x00l\x17\x00\x00n\x17\x00\x00p\x17\x00\x00\x80\x17\x00\x00\xb3\x17\x00\x00\xd7\x17\x00\x00\xd7\x17\x00\x00\xdc\x17\x00\x00\xdc\x17\x00\x00 \x18\x00\x00x\x18\x00\x00\x80\x18\x00\x00\x84\x18\x00\x00\x87\x18\x00\x00\xa8\x18\x00\x00\xaa\x18\x00\x00\xaa\x18\x00\x00\xb0\x18\x00\x00\xf5\x18\x00\x00\x00\x19\x00\x00\x1e\x19\x00\x00P\x19\x00\x00m\x19\x00\x00p\x19\x00\x00t\x19\x00\x00\x80\x19\x00\x00\xab\x19\x00\x00\xb0\x19\x00\x00\xc9\x19\x00\x00\x00\x1a\x00\x00\x16\x1a\x00\x00 \x1a\x00\x00T\x1a\x00\x00\xa7\x1a\x00\x00\xa7\x1a\x00\x00\x05\x1b\x00\x003\x1b\x00\x00E\x1b\x00\x00K\x1b\x00\x00\x83\x1b\x00\x00\xa0\x1b\x00\x00\xae\x1b\x00\x00\xaf\x1b\x00\x00\xba\x1b\x00\x00\xe5\x1b\x00\x00\x00\x1c\x00\x00#\x1c\x00\x00M\x1c\x00\x00O\x1c\x00\x00Z\x1c\x00\x00}\x1c\x00\x00\x80\x1c\x00\x00\x88\x1c\x00\x00\x90\x1c\x00\x00\xba\x1c\x00\x00\xbd\x1c\x00\x00\xbf\x1c\x00\x00\xe9\x1c\x00\x00\xec\x1c\x00\x00\xee\x1c\x00\x00\xf3\x1c\x00\x00\xf5\x1c\x00\x00\xf6\x1c\x00\x00\xfa\x1c\x00\x00\xfa\x1c\x00\x00\x00\x1d\x00\x00\xbf\x1d\x00\x00\x00\x1e\x00\x00\x15\x1f\x00\x00\x18\x1f\x00\x00\x1d\x1f\x00\x00 \x1f\x00\x00E\x1f\x00\x00H\x1f\x00\x00M\x1f\x00\x00P\x1f\x00\x00W\x1f\x00\x00Y\x1f\x00\x00Y\x1f\x00\x00[\x1f\x00\x00[\x1f\x00\x00]\x1f\x00\x00]\x1f\x00\x00_\x1f\x00\x00}\x1f\x00\x00\x80\x1f\x00\x00\xb4\x1f\x00\x00\xb6\x1f\x00\x00\xbc\x1f\x00\x00\xbe\x1f\x00\x00\xbe\x1f\x00\x00\xc2\x1f\x00\x00\xc4\x1f\x00\x00\xc6\x1f\x00\x00\xcc\x1f\x00\x00\xd0\x1f\x00\x00\xd3\x1f\x00\x00\xd6\x1f\x00\x00\xdb\x1f\x00\x00\xe0\x1f\x00\x00\xec\x1f\x00\x00\xf2\x1f\x00\x00\xf4\x1f\x00\x00\xf6\x1f\x00\x00\xfc\x1f\x00\x00q \x00\x00q \x00\x00\x7f \x00\x00\x7f \x00\x00\x90 \x00\x00\x9c \x00\x00\x02!\x00\x00\x02!\x00\x00\x07!\x00\x00\x07!\x00\x00\n!\x00\x00\x13!\x00\x00\x15!\x00\x00\x15!\x00\x00\x19!\x00\x00\x1d!\x00\x00$!\x00\x00$!\x00\x00&!\x00\x00&!\x00\x00(!\x00\x00(!\x00\x00*!\x00\x00-!\x00\x00/!\x00\x009!\x00\x00<!\x00\x00?!\x00\x00E!\x00\x00I!\x00\x00N!\x00\x00N!\x00\x00\x83!\x00\x00\x84!\x00\x00\x00,\x00\x00.,\x00\x000,\x00\x00^,\x00\x00`,\x00\x00\xe4,\x00\x00\xeb,\x00\x00\xee,\x00\x00\xf2,\x00\x00\xf3,\x00\x00\x00-\x00\x00%-\x00\x00\'-\x00\x00\'-\x00\x00--\x00\x00--\x00\x000-\x00\x00g-\x00\x00o-\x00\x00o-\x00\x00\x80-\x00\x00\x96-\x00\x00\xa0-\x00\x00\xa6-\x00\x00\xa8-\x00\x00\xae-\x00\x00\xb0-\x00\x00\xb6-\x00\x00\xb8-\x00\x00\xbe-\x00\x00\xc0-\x00\x00\xc6-\x00\x00\xc8-\x00\x00\xce-\x00\x00\xd0-\x00\x00\xd6-\x00\x00\xd8-\x00\x00\xde-\x00\x00/.\x00\x00/.\x00\x00\x050\x00\x00\x060\x00\x0010\x00\x0050\x00\x00;0\x00\x00<0\x00\x00A0\x00\x00\x960\x00\x00\x9d0\x00\x00\x9f0\x00\x00\xa10\x00\x00\xfa0\x00\x00\xfc0\x00\x00\xff0\x00\x00\x051\x00\x00/1\x00\x0011\x00\x00\x8e1\x00\x00\xa01\x00\x00\xbf1\x00\x00\xf01\x00\x00\xff1\x00\x00\x004\x00\x00\xbfM\x00\x00\x00N\x00\x00\xfc\x9f\x00\x00\x00\xa0\x00\x00\x8c\xa4\x00\x00\xd0\xa4\x00\x00\xfd\xa4\x00\x00\x00\xa5\x00\x00\x0c\xa6\x00\x00\x10\xa6\x00\x00\x1f\xa6\x00\x00*\xa6\x00\x00+\xa6\x00\x00@\xa6\x00\x00n\xa6\x00\x00\x7f\xa6\x00\x00\x9d\xa6\x00\x00\xa0\xa6\x00\x00\xe5\xa6\x00\x00\x17\xa7\x00\x00\x1f\xa7\x00\x00\"\xa7\x00\x00\x88\xa7\x00\x00\x8b\xa7\x00\x00\xbf\xa7\x00\x00\xc2\xa7\x00\x00\xca\xa7\x00\x00\xf5\xa7\x00\x00\x01\xa8\x00\x00\x03\xa8\x00\x00\x05\xa8\x00\x00\x07\xa8\x00\x00\n\xa8\x00\x00\x0c\xa8\x00\x00\"\xa8\x00\x00@\xa8\x00\x00s\xa8\x00\x00\x82\xa8\x00\x00\xb3\xa8\x00\x00\xf2\xa8\x00\x00\xf7\xa8\x00\x00\xfb\xa8\x00\x00\xfb\xa8\x00\x00\xfd\xa8\x00\x00\xfe\xa8\x00\x00\n\xa9\x00\x00%\xa9\x00\x000\xa9\x00\x00F\xa9\x00\x00`\xa9\x00\x00|\xa9\x00\x00\x84\xa9\x00\x00\xb2\xa9\x00\x00\xcf\xa9\x00\x00\xcf\xa9\x00\x00\xe0\xa9\x00\x00\xe4\xa9\x00\x00\xe6\xa9\x00\x00\xef\xa9\x00\x00\xfa\xa9\x00\x00\xfe\xa9\x00\x00\x00\xaa\x00\x00(\xaa\x00\x00@\xaa\x00\x00B\xaa\x00\x00D\xaa\x00\x00K\xaa\x00\x00`\xaa\x00\x00v\xaa\x00\x00z\xaa\x00\x00z\xaa\x00\x00~\xaa\x00\x00\xaf\xaa\x00\x00\xb1\xaa\x00\x00\xb1\xaa\x00\x00\xb5\xaa\x00\x00\xb6\xaa\x00\x00\xb9\xaa\x00\x00\xbd\xaa\x00\x00\xc0\xaa\x00\x00\xc0\xaa\x00\x00\xc2\xaa\x00\x00\xc2\xaa\x00\x00\xdb\xaa\x00\x00\xdd\xaa\x00\x00\xe0\xaa\x00\x00\xea\xaa\x00\x00\xf2\xaa\x00\x00\xf4\xaa\x00\x00\x01\xab\x00\x00\x06\xab\x00\x00\t\xab\x00\x00\x0e\xab\x00\x00\x11\xab\x00\x00\x16\xab\x00\x00 \xab\x00\x00&\xab\x00\x00(\xab\x00\x00.\xab\x00\x000\xab\x00\x00Z\xab\x00\x00\\\xab\x00\x00i\xab\x00\x00p\xab\x00\x00\xe2\xab\x00\x00\x00\xac\x00\x00\xa3\xd7\x00\x00\xb0\xd7\x00\x00\xc6\xd7\x00\x00\xcb\xd7\x00\x00\xfb\xd7\x00\x00\x00\xf9\x00\x00m\xfa\x00\x00p\xfa\x00\x00\xd9\xfa\x00\x00\x00\xfb\x00\x00\x06\xfb\x00\x00\x13\xfb\x00\x00\x17\xfb\x00\x00\x1d\xfb\x00\x00\x1d\xfb\x00\x00\x1f\xfb\x00\x00(\xfb\x00\x00*\xfb\x00\x006\xfb\x00\x008\xfb\x00\x00<\xfb\x00\x00>\xfb\x00\x00>\xfb\x00\x00@\xfb\x00\x00A\xfb\x00\x00C\xfb\x00\x00D\xfb\x00\x00F\xfb\x00\x00\xb1\xfb\x00\x00\xd3\xfb\x00\x00=\xfd\x00\x00P\xfd\x00\x00\x8f\xfd\x00\x00\x92\xfd\x00\x00\xc7\xfd\x00\x00\xf0\xfd\x00\x00\xfb\xfd\x00\x00p\xfe\x00\x00t\xfe\x00\x00v\xfe\x00\x00\xfc\xfe\x00\x00!\xff\x00\x00:\xff\x00\x00A\xff\x00\x00Z\xff\x00\x00f\xff\x00\x00\xbe\xff\x00\x00\xc2\xff\x00\x00\xc7\xff\x00\x00\xca\xff\x00\x00\xcf\xff\x00\x00\xd2\xff\x00\x00\xd7\xff\x00\x00\xda\xff\x00\x00\xdc\xff\x00\x00\x00\x00\x01\x00\x0b\x00\x01\x00\r\x00\x01\x00&\x00\x01\x00(\x00\x01\x00:\x00\x01\x00<\x00\x01\x00=\x00\x01\x00?\x00\x01\x00M\x00\x01\x00P\x00\x01\x00]\x00\x01\x00\x80\x00\x01\x00\xfa\x00\x01\x00\x80\x02\x01\x00\x9c\x02\x01\x00\xa0\x02\x01\x00\xd0\x02\x01\x00\x00\x03\x01\x00\x1f\x03\x01\x00-\x03\x01\x00@\x03\x01\x00B\x03\x01\x00I\x03\x01\x00P\x03\x01\x00u\x03\x01\x00\x80\x03\x01\x00\x9d\x03\x01\x00\xa0\x03\x01\x00\xc3\x03\x01\x00\xc8\x03\x01\x00\xcf\x03\x01\x00\x00\x04\x01\x00\x9d\x04\x01\x00\xb0\x04\x01\x00\xd3\x04\x01\x00\xd8\x04\x01\x00\xfb\x04\x01\x00\x00\x05\x01\x00\'\x05\x01\x000\x05\x01\x00c\x05\x01\x00\x00\x06\x01\x006\x07\x01\x00@\x07\x01\x00U\x07\x01\x00`\x07\x01\x00g\x07\x01\x00\x00\x08\x01\x00\x05\x08\x01\x00\x08\x08\x01\x00\x08\x08\x01\x00\n\x08\x01\x005\x08\x01\x007\x08\x01\x008\x08\x01\x00<\x08\x01\x00<\x08\x01\x00?\x08\x01\x00U\x08\x01\x00`\x08\x01\x00v\x08\x01\x00\x80\x08\x01\x00\x9e\x08\x01\x00\xe0\x08\x01\x00\xf2\x08\x01\x00\xf4\x08\x01\x00\xf5\x08\x01\x00\x00\t\x01\x00\x15\t\x01\x00 \t\x01\x009\t\x01\x00\x80\t\x01\x00\xb7\t\x01\x00\xbe\t\x01\x00\xbf\t\x01\x00\x00\n\x01\x00\x00\n\x01\x00\x10\n\x01\x00\x13\n\x01\x00\x15\n\x01\x00\x17\n\x01\x00\x19\n\x01\x005\n\x01\x00`\n\x01\x00|\n\x01\x00\x80\n\x01\x00\x9c\n\x01\x00\xc0\n\x01\x00\xc7\n\x01\x00\xc9\n\x01\x00\xe4\n\x01\x00\x00\x0b\x01\x005\x0b\x01\x00@\x0b\x01\x00U\x0b\x01\x00`\x0b\x01\x00r\x0b\x01\x00\x80\x0b\x01\x00\x91\x0b\x01\x00\x00\x0c\x01\x00H\x0c\x01\x00\x80\x0c\x01\x00\xb2\x0c\x01\x00\xc0\x0c\x01\x00\xf2\x0c\x01\x00\x00\r\x01\x00#\r\x01\x00\x80\x0e\x01\x00\xa9\x0e\x01\x00\xb0\x0e\x01\x00\xb1\x0e\x01\x00\x00\x0f\x01\x00\x1c\x0f\x01\x00\'\x0f\x01\x00\'\x0f\x01\x000\x0f\x01\x00E\x0f\x01\x00\xb0\x0f\x01\x00\xc4\x0f\x01\x00\xe0\x0f\x01\x00\xf6\x0f\x01\x00\x03\x10\x01\x007\x10\x01\x00\x83\x10\x01\x00\xaf\x10\x01\x00\xd0\x10\x01\x00\xe8\x10\x01\x00\x03\x11\x01\x00&\x11\x01\x00D\x11\x01\x00D\x11\x01\x00G\x11\x01\x00G\x11\x01\x00P\x11\x01\x00r\x11\x01\x00v\x11\x01\x00v\x11\x01\x00\x83\x11\x01\x00\xb2\x11\x01\x00\xc1\x11\x01\x00\xc4\x11\x01\x00\xda\x11\x01\x00\xda\x11\x01\x00\xdc\x11\x01\x00\xdc\x11\x01\x00\x00\x12\x01\x00\x11\x12\x01\x00\x13\x12\x01\x00+\x12\x01\x00\x80\x12\x01\x00\x86\x12\x01\x00\x88\x12\x01\x00\x88\x12\x01\x00\x8a\x12\x01\x00\x8d\x12\x01\x00\x8f\x12\x01\x00\x9d\x12\x01\x00\x9f\x12\x01\x00\xa8\x12\x01\x00\xb0\x12\x01\x00\xde\x12\x01\x00\x05\x13\x01\x00\x0c\x13\x01\x00\x0f\x13\x01\x00\x10\x13\x01\x00\x13\x13\x01\x00(\x13\x01\x00*\x13\x01\x000\x13\x01\x002\x13\x01\x003\x13\x01\x005\x13\x01\x009\x13\x01\x00=\x13\x01\x00=\x13\x01\x00P\x13\x01\x00P\x13\x01\x00]\x13\x01\x00a\x13\x01\x00\x00\x14\x01\x004\x14\x01\x00G\x14\x01\x00J\x14\x01\x00_\x14\x01\x00a\x14\x01\x00\x80\x14\x01\x00\xaf\x14\x01\x00\xc4\x14\x01\x00\xc5\x14\x01\x00\xc7\x14\x01\x00\xc7\x14\x01\x00\x80\x15\x01\x00\xae\x15\x01\x00\xd8\x15\x01\x00\xdb\x15\x01\x00\x00\x16\x01\x00/\x16\x01\x00D\x16\x01\x00D\x16\x01\x00\x80\x16\x01\x00\xaa\x16\x01\x00\xb8\x16\x01\x00\xb8\x16\x01\x00\x00\x17\x01\x00\x1a\x17\x01\x00\x00\x18\x01\x00+\x18\x01\x00\xa0\x18\x01\x00\xdf\x18\x01\x00\xff\x18\x01\x00\x06\x19\x01\x00\t\x19\x01\x00\t\x19\x01\x00\x0c\x19\x01\x00\x13\x19\x01\x00\x15\x19\x01\x00\x16\x19\x01\x00\x18\x19\x01\x00/\x19\x01\x00?\x19\x01\x00?\x19\x01\x00A\x19\x01\x00A\x19\x01\x00\xa0\x19\x01\x00\xa7\x19\x01\x00\xaa\x19\x01\x00\xd0\x19\x01\x00\xe1\x19\x01\x00\xe1\x19\x01\x00\xe3\x19\x01\x00\xe3\x19\x01\x00\x00\x1a\x01\x00\x00\x1a\x01\x00\x0b\x1a\x01\x002\x1a\x01\x00:\x1a\x01\x00:\x1a\x01\x00P\x1a\x01\x00P\x1a\x01\x00\\\x1a\x01\x00\x89\x1a\x01\x00\x9d\x1a\x01\x00\x9d\x1a\x01\x00\xc0\x1a\x01\x00\xf8\x1a\x01\x00\x00\x1c\x01\x00\x08\x1c\x01\x00\n\x1c\x01\x00.\x1c\x01\x00@\x1c\x01\x00@\x1c\x01\x00r\x1c\x01\x00\x8f\x1c\x01\x00\x00\x1d\x01\x00\x06\x1d\x01\x00\x08\x1d\x01\x00\t\x1d\x01\x00\x0b\x1d\x01\x000\x1d\x01\x00F\x1d\x01\x00F\x1d\x01\x00`\x1d\x01\x00e\x1d\x01\x00g\x1d\x01\x00h\x1d\x01\x00j\x1d\x01\x00\x89\x1d\x01\x00\x98\x1d\x01\x00\x98\x1d\x01\x00\xe0\x1e\x01\x00\xf2\x1e\x01\x00\xb0\x1f\x01\x00\xb0\x1f\x01\x00\x00 \x01\x00\x99#\x01\x00\x80$\x01\x00C%\x01\x00\x000\x01\x00.4\x01\x00\x00D\x01\x00FF\x01\x00\x00h\x01\x008j\x01\x00@j\x01\x00^j\x01\x00\xd0j\x01\x00\xedj\x01\x00\x00k\x01\x00/k\x01\x00@k\x01\x00Ck\x01\x00ck\x01\x00wk\x01\x00}k\x01\x00\x8fk\x01\x00@n\x01\x00\x7fn\x01\x00\x00o\x01\x00Jo\x01\x00Po\x01\x00Po\x01\x00\x93o\x01\x00\x9fo\x01\x00\xe0o\x01\x00\xe1o\x01\x00\xe3o\x01\x00\xe3o\x01\x00\x00p\x01\x00\xf7\x87\x01\x00\x00\x88\x01\x00\xd5\x8c\x01\x00\x00\x8d\x01\x00\x08\x8d\x01\x00\x00\xb0\x01\x00\x1e\xb1\x01\x00P\xb1\x01\x00R\xb1\x01\x00d\xb1\x01\x00g\xb1\x01\x00p\xb1\x01\x00\xfb\xb2\x01\x00\x00\xbc\x01\x00j\xbc\x01\x00p\xbc\x01\x00|\xbc\x01\x00\x80\xbc\x01\x00\x88\xbc\x01\x00\x90\xbc\x01\x00\x99\xbc\x01\x00\x00\xd4\x01\x00T\xd4\x01\x00V\xd4\x01\x00\x9c\xd4\x01\x00\x9e\xd4\x01\x00\x9f\xd4\x01\x00\xa2\xd4\x01\x00\xa2\xd4\x01\x00\xa5\xd4\x01\x00\xa6\xd4\x01\x00\xa9\xd4\x01\x00\xac\xd4\x01\x00\xae\xd4\x01\x00\xb9\xd4\x01\x00\xbb\xd4\x01\x00\xbb\xd4\x01\x00\xbd\xd4\x01\x00\xc3\xd4\x01\x00\xc5\xd4\x01\x00\x05\xd5\x01\x00\x07\xd5\x01\x00\n\xd5\x01\x00\r\xd5\x01\x00\x14\xd5\x01\x00\x16\xd5\x01\x00\x1c\xd5\x01\x00\x1e\xd5\x01\x009\xd5\x01\x00;\xd5\x01\x00>\xd5\x01\x00@\xd5\x01\x00D\xd5\x01\x00F\xd5\x01\x00F\xd5\x01\x00J\xd5\x01\x00P\xd5\x01\x00R\xd5\x01\x00\xa5\xd6\x01\x00\xa8\xd6\x01\x00\xc0\xd6\x01\x00\xc2\xd6\x01\x00\xda\xd6\x01\x00\xdc\xd6\x01\x00\xfa\xd6\x01\x00\xfc\xd6\x01\x00\x14\xd7\x01\x00\x16\xd7\x01\x004\xd7\x01\x006\xd7\x01\x00N\xd7\x01\x00P\xd7\x01\x00n\xd7\x01\x00p\xd7\x01\x00\x88\xd7\x01\x00\x8a\xd7\x01\x00\xa8\xd7\x01\x00\xaa\xd7\x01\x00\xc2\xd7\x01\x00\xc4\xd7\x01\x00\xcb\xd7\x01\x00\x00\xe1\x01\x00,\xe1\x01\x007\xe1\x01\x00=\xe1\x01\x00N\xe1\x01\x00N\xe1\x01\x00\xc0\xe2\x01\x00\xeb\xe2\x01\x00\x00\xe8\x01\x00\xc4\xe8\x01\x00\x00\xe9\x01\x00C\xe9\x01\x00K\xe9\x01\x00K\xe9\x01\x00\x00\xee\x01\x00\x03\xee\x01\x00\x05\xee\x01\x00\x1f\xee\x01\x00!\xee\x01\x00\"\xee\x01\x00$\xee\x01\x00$\xee\x01\x00\'\xee\x01\x00\'\xee\x01\x00)\xee\x01\x002\xee\x01\x004\xee\x01\x007\xee\x01\x009\xee\x01\x009\xee\x01\x00;\xee\x01\x00;\xee\x01\x00B\xee\x01\x00B\xee\x01\x00G\xee\x01\x00G\xee\x01\x00I\xee\x01\x00I\xee\x01\x00K\xee\x01\x00K\xee\x01\x00M\xee\x01\x00O\xee\x01\x00Q\xee\x01\x00R\xee\x01\x00T\xee\x01\x00T\xee\x01\x00W\xee\x01\x00W\xee\x01\x00Y\xee\x01\x00Y\xee\x01\x00[\xee\x01\x00[\xee\x01\x00]\xee\x01\x00]\xee\x01\x00_\xee\x01\x00_\xee\x01\x00a\xee\x01\x00b\xee\x01\x00d\xee\x01\x00d\xee\x01\x00g\xee\x01\x00j\xee\x01\x00l\xee\x01\x00r\xee\x01\x00t\xee\x01\x00w\xee\x01\x00y\xee\x01\x00|\xee\x01\x00~\xee\x01\x00~\xee\x01\x00\x80\xee\x01\x00\x89\xee\x01\x00\x8b\xee\x01\x00\x9b\xee\x01\x00\xa1\xee\x01\x00\xa3\xee\x01\x00\xa5\xee\x01\x00\xa9\xee\x01\x00\xab\xee\x01\x00\xbb\xee\x01\x00\x00\x00\x02\x00\xdd\xa6\x02\x00\x00\xa7\x02\x004\xb7\x02\x00@\xb7\x02\x00\x1d\xb8\x02\x00 \xb8\x02\x00\xa1\xce\x02\x00\xb0\xce\x02\x00\xe0\xeb\x02\x00\x00\xf8\x02\x00\x1d\xfa\x02\x00\x00\x00\x03\x00J\x13\x03\x000\x00\x00\x009\x00\x00\x00\xb2\x00\x00\x00\xb3\x00\x00\x00\xb9\x00\x00\x00\xb9\x00\x00\x00\xbc\x00\x00\x00\xbe\x00\x00\x00`\x06\x00\x00i\x06\x00\x00\xf0\x06\x00\x00\xf9\x06\x00\x00\xc0\x07\x00\x00\xc9\x07\x00\x00f\t\x00\x00o\t\x00\x00\xe6\t\x00\x00\xef\t\x00\x00\xf4\t\x00\x00\xf9\t\x00\x00f\n\x00\x00o\n\x00\x00\xe6\n\x00\x00\xef\n\x00\x00f\x0b\x00\x00o\x0b\x00\x00r\x0b\x00\x00w\x0b\x00\x00\xe6\x0b\x00\x00\xf2\x0b\x00\x00f\x0c\x00\x00o\x0c\x00\x00x\x0c\x00\x00~\x0c\x00\x00\xe6\x0c\x00\x00\xef\x0c\x00\x00X\r\x00\x00^\r\x00\x00f\r\x00\x00x\r\x00\x00\xe6\r\x00\x00\xef\r\x00\x00P\x0e\x00\x00Y\x0e\x00\x00\xd0\x0e\x00\x00\xd9\x0e\x00\x00 \x0f\x00\x003\x0f\x00\x00@\x10\x00\x00I\x10\x00\x00\x90\x10\x00\x00\x99\x10\x00\x00i\x13\x00\x00|\x13\x00\x00\xee\x16\x00\x00\xf0\x16\x00\x00\xe0\x17\x00\x00\xe9\x17\x00\x00\xf0\x17\x00\x00\xf9\x17\x00\x00\x10\x18\x00\x00\x19\x18\x00\x00F\x19\x00\x00O\x19\x00\x00\xd0\x19\x00\x00\xda\x19\x00\x00\x80\x1a\x00\x00\x89\x1a\x00\x00\x90\x1a\x00\x00\x99\x1a\x00\x00P\x1b\x00\x00Y\x1b\x00\x00\xb0\x1b\x00\x00\xb9\x1b\x00\x00@\x1c\x00\x00I\x1c\x00\x00P\x1c\x00\x00Y\x1c\x00\x00p \x00\x00p \x00\x00t \x00\x00y \x00\x00\x80 \x00\x00\x89 \x00\x00P!\x00\x00\x82!\x00\x00\x85!\x00\x00\x89!\x00\x00`$\x00\x00\x9b$\x00\x00\xea$\x00\x00\xff$\x00\x00v\'\x00\x00\x93\'\x00\x00\xfd,\x00\x00\xfd,\x00\x00\x070\x00\x00\x070\x00\x00!0\x00\x00)0\x00\x0080\x00\x00:0\x00\x00\x921\x00\x00\x951\x00\x00 2\x00\x00)2\x00\x00H2\x00\x00O2\x00\x00Q2\x00\x00_2\x00\x00\x802\x00\x00\x892\x00\x00\xb12\x00\x00\xbf2\x00\x00 \xa6\x00\x00)\xa6\x00\x00\xe6\xa6\x00\x00\xef\xa6\x00\x000\xa8\x00\x005\xa8\x00\x00\xd0\xa8\x00\x00\xd9\xa8\x00\x00\x00\xa9\x00\x00\t\xa9\x00\x00\xd0\xa9\x00\x00\xd9\xa9\x00\x00\xf0\xa9\x00\x00\xf9\xa9\x00\x00P\xaa\x00\x00Y\xaa\x00\x00\xf0\xab\x00\x00\xf9\xab\x00\x00\x10\xff\x00\x00\x19\xff\x00\x00\x07\x01\x01\x003\x01\x01\x00@\x01\x01\x00x\x01\x01\x00\x8a\x01\x01\x00\x8b\x01\x01\x00\xe1\x02\x01\x00\xfb\x02\x01\x00 \x03\x01\x00#\x03\x01\x00A\x03\x01\x00A\x03\x01\x00J\x03\x01\x00J\x03\x01\x00\xd1\x03\x01\x00\xd5\x03\x01\x00\xa0\x04\x01\x00\xa9\x04\x01\x00X\x08\x01\x00_\x08\x01\x00y\x08\x01\x00\x7f\x08\x01\x00\xa7\x08\x01\x00\xaf\x08\x01\x00\xfb\x08\x01\x00\xff\x08\x01\x00\x16\t\x01\x00\x1b\t\x01\x00\xbc\t\x01\x00\xbd\t\x01\x00\xc0\t\x01\x00\xcf\t\x01\x00\xd2\t\x01\x00\xff\t\x01\x00@\n\x01\x00H\n\x01\x00}\n\x01\x00~\n\x01\x00\x9d\n\x01\x00\x9f\n\x01\x00\xeb\n\x01\x00\xef\n\x01\x00X\x0b\x01\x00_\x0b\x01\x00x\x0b\x01\x00\x7f\x0b\x01\x00\xa9\x0b\x01\x00\xaf\x0b\x01\x00\xfa\x0c\x01\x00\xff\x0c\x01\x000\r\x01\x009\r\x01\x00`\x0e\x01\x00~\x0e\x01\x00\x1d\x0f\x01\x00&\x0f\x01\x00Q\x0f\x01\x00T\x0f\x01\x00\xc5\x0f\x01\x00\xcb\x0f\x01\x00R\x10\x01\x00o\x10\x01\x00\xf0\x10\x01\x00\xf9\x10\x01\x006\x11\x01\x00?\x11\x01\x00\xd0\x11\x01\x00\xd9\x11\x01\x00\xe1\x11\x01\x00\xf4\x11\x01\x00\xf0\x12\x01\x00\xf9\x12\x01\x00P\x14\x01\x00Y\x14\x01\x00\xd0\x14\x01\x00\xd9\x14\x01\x00P\x16\x01\x00Y\x16\x01\x00\xc0\x16\x01\x00\xc9\x16\x01\x000\x17\x01\x00;\x17\x01\x00\xe0\x18\x01\x00\xf2\x18\x01\x00P\x19\x01\x00Y\x19\x01\x00P\x1c\x01\x00l\x1c\x01\x00P\x1d\x01\x00Y\x1d\x01\x00\xa0\x1d\x01\x00\xa9\x1d\x01\x00\xc0\x1f\x01\x00\xd4\x1f\x01\x00\x00$\x01\x00n$\x01\x00`j\x01\x00ij\x01\x00Pk\x01\x00Yk\x01\x00[k\x01\x00ak\x01\x00\x80n\x01\x00\x96n\x01\x00\xe0\xd2\x01\x00\xf3\xd2\x01\x00`\xd3\x01\x00x\xd3\x01\x00\xce\xd7\x01\x00\xff\xd7\x01\x00@\xe1\x01\x00I\xe1\x01\x00\xf0\xe2\x01\x00\xf9\xe2\x01\x00\xc7\xe8\x01\x00\xcf\xe8\x01\x00P\xe9\x01\x00Y\xe9\x01\x00q\xec\x01\x00\xab\xec\x01\x00\xad\xec\x01\x00\xaf\xec\x01\x00\xb1\xec\x01\x00\xb4\xec\x01\x00\x01\xed\x01\x00-\xed\x01\x00/\xed\x01\x00=\xed\x01\x00\x00\xf1\x01\x00\x0c\xf1\x01\x00\xf0\xfb\x01\x00\xf9\xfb\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\t\x00\x00\x00\r\x00\x00\x00 \x00\x00\x00 \x00\x00\x00\x85\x00\x00\x00\x85\x00\x00\x00\xa0\x00\x00\x00\xa0\x00\x00\x00\x80\x16\x00\x00\x80\x16\x00\x00\x00 \x00\x00\n \x00\x00( \x00\x00) \x00\x00/ \x00\x00/ \x00\x00_ \x00\x00_ \x00\x00\x000\x00\x00\x000\x00\x00Success\x00Illegal byte sequence\x00Domain error\x00Result not representable\x00Not a tty\x00Permission denied\x00Operation not permitted\x00No such file or directory\x00No such process\x00File exists\x00Value too large for data type\x00No space left on device\x00Out of memory\x00Resource busy\x00Interrupted system call\x00Resource temporarily unavailable\x00Invalid seek\x00Cross-device link\x00Read-only file system\x00Directory not empty\x00Connection reset by peer\x00Operation timed out\x00Connection refused\x00Host is unreachable\x00Address in use\x00Broken pipe\x00I/O error\x00No such device or address\x00No such device\x00Not a directory\x00Is a directory\x00Text file busy\x00Exec format error\x00Invalid argument\x00Argument list too long\x00Symbolic link loop\x00Filename too long\x00Too many open files in system\x00No file descriptors available\x00Bad file descriptor\x00No child process\x00Bad address\x00File too large\x00Too many links\x00No locks available\x00Resource deadlock would occur\x00State not recoverable\x00Previous owner died\x00Operation canceled\x00Function not implemented\x00No message of desired type\x00Identifier removed\x00Link has been severed\x00Protocol error\x00Bad message\x00Not a socket\x00Destination address required\x00Message too large\x00Protocol wrong type for socket\x00Protocol not available\x00Protocol not supported\x00Not supported\x00Address family not supported by protocol\x00Address not available\x00Network is down\x00Network unreachable\x00Connection reset by network\x00Connection aborted\x00No buffer space available\x00Socket is connected\x00Socket not connected\x00Operation already in progress\x00Operation in progress\x00Stale file handle\x00Quota exceeded\x00Multihop attempted\x00Capabilities insufficient\x00\x00\x00u\x02N\x00\xd6\x01\xe2\x04\xb9\x04\x18\x01\x8e\x05\xed\x02\x16\x04\xf2\x00\x97\x03\x01\x038\x05\xaf\x01\x82\x01O\x03/\x04\x1e\x00\xd4\x05\xa2\x00\x12\x03\x1e\x03\xc2\x01\xde\x03\x08\x00\xac\x05\x00\x01d\x02\xf1\x01e\x054\x02\x8c\x02\xcf\x02-\x03L\x04\xe3\x05\x9f\x02\xf8\x04\x1c\x05\x08\x05\xb1\x02K\x05\x15\x02x\x00R\x02<\x03\xf1\x03\xe4\x00\xc3\x03}\x04\xcc\x00\xaa\x03y\x05$\x02n\x01m\x03\"\x04\xab\x04D\x00\xfb\x01\xae\x00\x83\x03`\x00\xe5\x01\x07\x04\x94\x04^\x04+\x00X\x019\x01\x92\x00\xc2\x05\x9b\x01C\x02F\x01\xf6\x05\x00\x00\x00\x00\x00\x00\x19\x00\x0b\x00\x19\x19\x19\x00\x00\x00\x00\x05\x00\x00\x00\x00\x00\x00\t\x00\x00\x00\x00\x0b\x00\x00\x00\x00\x00\x00\x00\x00\x19\x00\n\n\x19\x19\x19\x03\n\x07\x00\x01\x1b\t\x0b\x18\x00\x00\t\x06\x0b\x00\x00\x0b\x00\x06\x19\x00\x00\x00\x19\x19\x19\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x0e\x00\x00\x00\x00\x00\x00\x00\x00\x19\x00\x0b\r\x19\x19\x19\x00\r\x00\x00\x02\x00\t\x0e\x00\x00\x00\t\x00\x0e\x00\x00\x0e\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x0c\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x13\x00\x00\x00\x00\x13\x00\x00\x00\x00\t\x0c\x00\x00\x00\x00\x00\x0c\x00\x00\x0c\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x10\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x0f\x00\x00\x00\x04\x0f\x00\x00\x00\x00\t\x10\x00\x00\x00\x00\x00\x10\x00\x00\x10\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x12\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x11\x00\x00\x00\x00\x11\x00\x00\x00\x00\t\x12\x00\x00\x00\x00\x00\x12\x00\x00\x12\x00\x00\x1a\x00\x00\x00\x1a\x1a\x1a\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x1a\x00\x00\x00\x1a\x1a\x1a\x00\x00\x00\x00\x00\x00\t\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x14\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x17\x00\x00\x00\x00\x17\x00\x00\x00\x00\t\x14\x00\x00\x00\x00\x00\x14\x00\x00\x14\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x16\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x15\x00\x00\x00\x00\x15\x00\x00\x00\x00\t\x16\x00\x00\x00\x00\x00\x16\x00\x00\x16\x00\x000123456789ABCDEF", }, 9648, 9648);
	rt_memory_copy(module_locals[3], (function(loc_2284_)
		local loc_2285_
		loc_2285_ = loc_2284_;
		return 1024, loc_2285_
	end)(), module_locals[167], 0, 9648)
	module_locals[168] = rt_memory_new({ [0] = "\x00\x00\x02\x00\x00\x00\x00\x00\x05\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\n\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x0b\x00\x00\x00\x07\x00\x00\x00\xb8k\x00\x00\x00\x04\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\n\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xb8)\x00\x00\x00\x00\x00\x00\x05\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\n\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x08\x00\x00\x00\x07\x00\x00\x00\xdco\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\xff\xff\xff\xff\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x000*\x00\x00", }, 244, 244);
	rt_memory_copy(module_locals[3], (function(loc_2286_)
		local loc_2287_
		loc_2287_ = loc_2286_;
		return 10672, loc_2287_
	end)(), module_locals[168], 0, 244)
	module_locals[164][1] = (function(loc_2288_)
		local loc_2289_
		loc_2289_ = loc_2288_;
		return 1077712, loc_2289_
	end)();
	module_locals[165][1] = (function(loc_2290_)
		local loc_2291_
		loc_2291_ = loc_2290_;
		return 0, loc_2291_
	end)();
	rt_table_drop(module_locals[166])
	rt_memory_drop(module_locals[167])
	rt_memory_drop(module_locals[168])
	module_locals[2] = module_locals[1];
	module_locals[31] = module_locals[4];
	module_locals[163] = module_locals[3];
	end)() end --[[/spider:chunk]]
	local export = {
		["memory"] = module_locals[3],
		["_start"] = module_locals[4][1],
		["__host"] = runtime.host_api,
	}
	return export
end
return module, runtime.host_api
