//! MPFR 4.2 ABI for the supported Apple Silicon macOS build.
//! Matches mpfr.h: long precision/exponent, int sign, unsigned-long limbs.
pub const mpfr_t = extern struct { precision: c_long, sign: c_int, exponent: c_long, limbs: [*]c_ulong };
pub const MPFR_RNDN: c_int = 0;
pub extern "c" fn mpfr_init2(*mpfr_t, c_long) void;
pub extern "c" fn mpfr_clear(*mpfr_t) void;
pub extern "c" fn mpfr_set_zero(*mpfr_t, c_int) void;
pub extern "c" fn mpfr_set(*mpfr_t, *const mpfr_t, c_int) c_int;
pub extern "c" fn mpfr_set_d(*mpfr_t, f64, c_int) c_int;
pub extern "c" fn mpfr_set_str(*mpfr_t, [*:0]const u8, c_int, c_int) c_int;
pub extern "c" fn mpfr_get_d(*const mpfr_t, c_int) f64;
pub extern "c" fn mpfr_prec_round(*mpfr_t, c_long, c_int) c_int;
pub extern "c" fn mpfr_mul_2si(*mpfr_t, *const mpfr_t, c_long, c_int) c_int;
pub extern "c" fn mpfr_mul_2ui(*mpfr_t, *const mpfr_t, c_ulong, c_int) c_int;
pub extern "c" fn mpfr_mul_d(*mpfr_t, *const mpfr_t, f64, c_int) c_int;
pub extern "c" fn mpfr_add(*mpfr_t, *const mpfr_t, *const mpfr_t, c_int) c_int;
pub extern "c" fn mpfr_sub(*mpfr_t, *const mpfr_t, *const mpfr_t, c_int) c_int;
pub extern "c" fn mpfr_mul(*mpfr_t, *const mpfr_t, *const mpfr_t, c_int) c_int;
pub extern "c" fn mpfr_div(*mpfr_t, *const mpfr_t, *const mpfr_t, c_int) c_int;
pub extern "c" fn mpfr_sqr(*mpfr_t, *const mpfr_t, c_int) c_int;
pub extern "c" fn mpfr_cmp(*const mpfr_t, *const mpfr_t) c_int;
pub extern "c" fn mpfr_free_cache() void;
pub extern "c" fn mpfr_get_str(?[*]u8, *c_long, c_int, usize, *const mpfr_t, c_int) ?[*:0]u8;
pub extern "c" fn mpfr_free_str([*:0]u8) void;
