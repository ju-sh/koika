/*! Preamble shared by all Kôika programs compiled to C++ !*/
#ifndef _PREAMBLE_HPP
#define _PREAMBLE_HPP

#include <algorithm> // For std::max
#include <array>
#include <cstddef> // For size_t
#include <cstdint>
#include <cstring> // For memcpy
#include <limits> // For std::numeric_limits used in prims::mask
#include <string> // For prims::display
#include <type_traits> // For std::conditional_t

#ifndef SIM_MINIMAL
#include <chrono> // For VCD headers
#include <iomanip> // For std::setfill
#include <iostream>
#include <fstream> // For VCD files
#endif // #ifndef SIM_MINIMAL

#ifdef SIM_DEBUG
#include <iostream>
static inline void _sim_assert_fn(const char* repr,
                        bool expr,
                        const char* file,
                        const int line,
                        const char* err_msg) {
  if (!expr) {
    std::cerr << file << ":" << line << ": "
              << err_msg << std::endl
              << "Failed assertion: " << repr;
    abort();
  }
}
#define _sim_assert(expr, msg) _sim_assert_fn(#expr, expr, __FILE__, __LINE__, msg)
#else
#define _sim_assert(expr, msg) ;
#endif // #ifdef SIM_DEBUG

#define _unused __attribute__((unused))

#if defined(__clang__)
#define _unoptimized __attribute__((optnone))
#elif defined(__GNUG__)
#define _unoptimized __attribute__((optimize("O0")))
#else
#define _unoptimized
#endif

#if defined(SIM_MINIMAL) && defined(SIM_KEEP_DISPLAY)
#define _display_unoptimized _unoptimized
#else
#define _display_unoptimized
#endif

#ifdef SIM_FLATTEN
#define _flatten __attribute__((flatten))
#else
#define _flatten
#endif

#define _noinline __attribute__((noinline))

#define _unlikely(b) __builtin_expect((b), 0)

#ifdef NEEDS_BOOST_MULTIPRECISION
#include <boost/multiprecision/cpp_int.hpp>
template<std::size_t size>
using wbits_t = std::conditional_t<size <= 128, boost::multiprecision::uint128_t,
                std::conditional_t<size <= 256, boost::multiprecision::uint256_t,
                std::conditional_t<size <= 512, boost::multiprecision::uint512_t,
                std::conditional_t<size <= 1024, boost::multiprecision::uint1024_t,
                                   void>>>>;
template<std::size_t size>
using wsbits_t = std::conditional_t<size <= 128, boost::multiprecision::int128_t,
                 std::conditional_t<size <= 256, boost::multiprecision::int256_t,
                 std::conditional_t<size <= 512, boost::multiprecision::int512_t,
                 std::conditional_t<size <= 1024, boost::multiprecision::int1024_t,
                                    void>>>>;
#else
template<std::size_t size>
using wbits_t = void;
template<std::size_t size>
using wsbits_t = void;
#endif // #ifdef NEEDS_BOOST_MULTIPRECISION

namespace cuttlesim {
  static _unused const char* version = "CuttleSim v0.0.1";
}

struct unit_t {};

template<std::size_t size>
using bits_t = std::conditional_t<size ==  0, unit_t,
               std::conditional_t<size <=  8, std::uint8_t,
               std::conditional_t<size <= 16, std::uint16_t,
               std::conditional_t<size <= 32, std::uint32_t,
               std::conditional_t<size <= 64, std::uint64_t,
                                  wbits_t<size>>>>>>;

template<std::size_t size>
using sbits_t = std::conditional_t<size ==  0, unit_t,
                std::conditional_t<size <=  8, std::int8_t,
                std::conditional_t<size <= 16, std::int16_t,
                std::conditional_t<size <= 32, std::int32_t,
                std::conditional_t<size <= 64, std::int64_t,
                                   wsbits_t<size>>>>>>;

namespace prims {
  using bitwidth = std::size_t;
  using size_t = std::size_t;

  template<typename T>
  T __attribute__((noreturn)) unreachable() {
    __builtin_unreachable();
  }

  static _unused void assume(bool condition) {
    if (!condition) { unreachable<void>(); }
  }

  template<typename T, size_t len>
  struct array : public std::array<T, len> { // Inherit to be able to overload ‘==’
    // https://stackoverflow.com/questions/24280521/
    // TODO: remove this constructor once we move to C++17
    template <typename... Args>
    // NOLINTNEXTLINE(google-explicit-constructor)
    array(Args&&... args) : std::array<T, len>({std::forward<Args>(args)...}) {}
  };

  template <bitwidth sz> struct bits;
  template <bitwidth sz> std::ostream& operator<<(std::ostream& /*os*/, const bits<sz>& /*bs*/);

  template<bitwidth sz>
  struct bits {
    bits_t<sz> v;

#ifndef __OPTIMIZE__
    // This makes debugging easier
    static constexpr bitwidth size = sz;
#endif

    /// Representation invariant

    static constexpr bitwidth padding_width() noexcept {
      // making this a function avoids polluting GDB's output
      return std::numeric_limits<bits_t<sz>>::digits - sz;
    }

    // Not constexpr because Boost's >> isn't constexpr
    static const bits_t<sz> bitmask() noexcept {
      auto pw = bits<sz>::padding_width(); // https://stackoverflow.com/questions/8452952/
      return std::numeric_limits<bits_t<sz>>::max() >> pw;
    }

    void invariant() const noexcept {
      // Knowing this invariant can sometimes help the compiler; it does in
      // particular in ‘operator bool()’ below.
      assume(v <= bitmask());
    }

    /// Casts

    sbits_t<sz> to_sbits() const {
      sbits_t<sz> sx; // FIXME does this work with multiprecision?
      std::memcpy(&sx, &this->v, sizeof sx);
      return sx;
    }

    static bits<sz> of_sbits(sbits_t<sz> sx) {
      bits_t<sz> x; // FIXME does this work with multiprecision?
      std::memcpy(&x, &sx, sizeof x);
      return bits<sz>::mk(x);
    }

    sbits_t<sz> to_shifted_sbits() const {
      return to_sbits() << bits<sz>::padding_width();
    }

    static bits<sz> of_shifted_sbits(sbits_t<sz> sx) {
      // This constructs an int of the same bitsize as x, with the same
      // bitpattern, except that it uses the high bits of the storage type instead
      // of the low ones (e.g. 4'b1101 is represented as 8'b11010000).
      return of_sbits(sx) >> bits<sz>::padding_width();
    }

    /// Constants

    static const bits<sz> ones() {
      return bits<sz>::mk(bits<sz>::bitmask());
    }

    /// Member functions

    explicit operator bool() const {
      invariant(); // Knowing this invariant helps GCC generate better code
      return bool(v); // Writing bool(v & bitmask()) works just as well
    }

    explicit operator bits_t<sz>() const {
      return v;
    }

    template<bitwidth idx_sz>
    bits<1> operator[](bits<idx_sz> idx) const;

    bits<sz>& operator&=(bits<sz> arg);
    bits<sz>& operator|=(bits<sz> arg);
    bits<sz>& operator^=(bits<sz> arg);
    bits<sz>& operator+=(bits<sz> arg);
    bits<sz>& operator-=(bits<sz> arg);
    bits<sz>& operator<<=(size_t shift);
    bits<sz>& operator>>=(size_t shift);
    template<bitwidth shift_sz> bits<sz>& operator<<=(bits<shift_sz> shift);
    template<bitwidth shift_sz> bits<sz>& operator>>=(bits<shift_sz> shift);

    // https://stackoverflow.com/questions/4660123/
    friend std::ostream& operator<<<sz>(std::ostream& os, const bits<sz>& bs);

    /// Constructors

    template<typename T>
    static constexpr bits<sz> mk(T arg) {
      return bits{static_cast<bits_t<sz>>(arg)};
    }
  };

  using unit = bits<0>;
  static const _unused unit tt{};

  namespace literal_parsing {
    template<uint base, char c>
    constexpr bool valid_digit() {
      switch (base) {
      case 2:
        return c == '0' || c == '1';
      case 10:
        return '0' <= c && c <= '9';
      case 16:
        return (('0' <= c && c <= '9') ||
                ('a' <= c && c <= 'f') || ('A' <= c && c <= 'F'));
      default:
        return false;
      }
    }

    template <uint base, char c>
    constexpr uint parse_digit() noexcept {
      static_assert(base == 2 || base == 10 || base == 16, "Invalid base");
      static_assert(valid_digit<base, c>(), "Invalid digit");
      if ('0' <= c && c <= '9') {
        return c - '0';
      } else if ('a' <= c && c <= 'f') {
        return c - 'a' + 10;
      } else if ('A' <= c && c <= 'F') {
        return c - 'A' + 10;
      } else {
        unreachable<uint>();
      }
    }

    template <uint base, uint64_t max, uint64_t num>
    constexpr uint64_t parse_u64() noexcept {
      return num;
    }

    template <uint base, uint64_t max, uint64_t num, char c, char... cs>
    constexpr uint64_t parse_u64() noexcept {
      const uint64_t digit = parse_digit<base, c>();
      static_assert((max - digit) / base >= num, "Overflow in literal parsing");
      return parse_u64<base, max, base * num + digit, cs...>();
    }

    enum class parser { u64, u128, u256, u512, u1024, unsupported };

    template <parser p, uint base, bitwidth sz, char... cs>
    struct parse_number {
      static_assert(p != parser::unsupported, "Unsupported bitsize.");
#ifndef NEEDS_BOOST_MULTIPRECISION
      static_assert(p == parser::u64, "Needs boost::multiprecision to parse numbers with > 64 bits.");
#endif
      static_assert(p == parser::u64 || base == 16, "boost::multiprecision only supports base-16 literals.");
    };

    template <uint base, bitwidth sz, char... cs>
    struct parse_number<parser::u64, base, sz, cs...> {
      static constexpr uint64_t max = std::numeric_limits<bits_t<sz>>::max() >> bits<sz>::padding_width();
      static constexpr bits_t<sz> v = parse_u64<base, max, 0, cs...>();
    };

#ifdef NEEDS_BOOST_MULTIPRECISION
    using namespace boost::multiprecision::literals;

    template <bitwidth sz, char... cs>
    struct parse_number<parser::u128, 16, sz, cs...> {
      static constexpr bits_t<sz> v = operator "" _cppui128<'0', 'x', cs...>();
    };

    template <bitwidth sz, char... cs>
    struct parse_number<parser::u256, 16, sz, cs...> {
      static constexpr bits_t<sz> v = operator "" _cppui256<'0', 'x', cs...>();
    };

    template <bitwidth sz, char... cs>
    struct parse_number<parser::u512, 16, sz, cs...> {
      static constexpr bits_t<sz> v = operator "" _cppui512<'0', 'x', cs...>();
    };

    template <bitwidth sz, char... cs>
    struct parse_number<parser::u1024, 16, sz, cs...> {
      static constexpr bits_t<sz> v = operator "" _cppui1024<'0', 'x', cs...>();
    };
#endif

    constexpr parser get_parser(bitwidth sz) noexcept {
      if (sz <= 64) {
        return parser::u64;
      } else if (sz <= 128) {
        return parser::u128;
      } else if (sz <= 256) {
        return parser::u256;
      } else if (sz <= 512) {
        return parser::u512;
      } else if (sz <= 1024) {
        return parser::u1024;
      } else {
        return parser::unsupported;
      }
    }

    template <bool imm, uint base, bitwidth sz, char... cs>
    struct parse_literal;

    template <uint base, bitwidth sz, char... cs>
    struct parse_literal<true, base, sz, '\'', cs...> {
      static_assert(sz <= 64, "Immediates can't have size > 64.");
      static constexpr bits_t<sz> v = parse_number<get_parser(sz), base, sz, cs...>::v;
    };

    template <uint base, bitwidth sz, char... cs>
    struct parse_literal<false, base, sz, '\'', cs...> {
      static constexpr bits<sz> v = bits<sz>{parse_number<get_parser(sz), base, sz, cs...>::v};
    };

    template <bool imm, uint base, bitwidth sz, char c, char... cs>
    struct parse_literal<imm, base, sz, c, cs...> {
      static constexpr bitwidth sz_digit = parse_digit<10, c>();
      static constexpr auto v = parse_literal<imm, base, 10 * sz + sz_digit, cs...>::v;
    };

    template <bool imm, char... cs>
    using parse_bin = parse_literal<imm, 2, 0, cs...>;

    template <bool imm, char... cs>
    using parse_dec = parse_literal<imm, 10, 0, cs...>;

    template <bool imm, char... cs> struct parse_hex;
    template <bool imm, char c0, char c1, char... cs>
    struct parse_hex<imm, c0, c1, cs...> {
      static_assert(c0 == '0' && c1 == 'x', "Hex literal must start with 0x");
      static constexpr auto v = parse_literal<imm, 16, 0, cs...>::v;
    };
  } // namespace literal_parsing

  namespace literals {
    // ‘auto v = …; return v’: see
    // * https://stackoverflow.com/questions/8452952/c-linker-error-with-class-static-constexpr
    // * https://stackoverflow.com/questions/45970113/
    // * https://stackoverflow.com/a/18940384/695591
    // … or compile with -std=c++17

    // Binary representation: 4'0010_b
    template <char... cs> constexpr auto operator "" _b() {
      constexpr auto v = literal_parsing::parse_bin<false, cs...>::v; return v;
    }

    // Decimal representation: 11'1234_d
    template <char... cs> constexpr auto operator "" _d() {
      constexpr auto v = literal_parsing::parse_dec<false, cs...>::v; return v;
    }

    // Hex representation: 0x16'abcd_x
    template <char... cs> constexpr auto operator "" _x() {
      constexpr auto v = literal_parsing::parse_hex<false, cs...>::v; return v;
    }

    // Immediate binary representation: 4'0010_bv
    template <char... cs> constexpr auto operator "" _bv() {
      constexpr auto v = literal_parsing::parse_bin<true, cs...>::v; return v;
    }

    // Immediate decimal representation: 11'1234_dv
    template <char... cs> constexpr auto operator "" _dv() {
      constexpr auto v = literal_parsing::parse_dec<true, cs...>::v; return v;
    }

    // Immediate hex representation: 0x16'abcd_xv
    template <char... cs> constexpr auto operator "" _xv() {
      constexpr auto v = literal_parsing::parse_hex<true, cs...>::v; return v;
    }
  } // namespace literals

  /// Functions on bits

  template<bitwidth sz>
  static bits<sz> mask(bits<sz> arg) {
    return arg & bits<sz>::ones();
  }

  template<bitwidth ret_sz, bitwidth sz>
  static bits<ret_sz> widen(const bits<sz> arg) {
    return bits<ret_sz>::mk(arg.v);
  }

  template<bitwidth ret_sz, bitwidth sz>
  static bits<ret_sz> truncate(const bits<sz> arg) {
    return mask(widen<ret_sz>(arg));
  }

  template<bitwidth sz>
  bits<1> msb(const bits<sz> arg) {
    return sz == 0 ? 0 : truncate<1>(arg >> (sz - 1));
  }

  template<bitwidth sz>
  template<bitwidth idx_sz>
  bits<1> bits<sz>::operator[](const bits<idx_sz> idx) const {
    return truncate<1>((*this) >> idx);
  }

  template<bitwidth idx, bitwidth sz1, bitwidth width>
  bits<sz1> slice_subst(const bits<sz1> data, const bits<width> repl) {
    const bits<sz1> mask = ~(widen<sz1>(bits<width>::ones()) << idx);
    return (data & mask) | (widen<sz1>(repl) << idx);
  }

  template<bitwidth width, bitwidth sz1, bitwidth sz2>
  bits<width> islice(const bits<sz1> data, const bits<sz2> idx) {
    return truncate<width>(data >> idx);
  }

  template<bitwidth sz>
  bits<sz> operator&(const bits<sz> data1, const bits<sz> data2) {
    return bits<sz>::mk(data1.v & data2.v);
  }

  template<bitwidth sz>
  bits<sz> operator|(const bits<sz> data1, const bits<sz> data2) {
    return bits<sz>::mk(data1.v | data2.v);
  }

  template<bitwidth sz>
  bits<sz> operator^(const bits<sz> data1, const bits<sz> data2) {
    return bits<sz>::mk(data1.v ^ data2.v);
  }

  template<bitwidth sz1, bitwidth sz2>
  bits<sz1> asr(const bits<sz1> data, const bits<sz2> shift) {
    return bits<sz1>::of_shifted_sbits(data.to_shifted_sbits() >> shift.v);
  }

  template<bitwidth sz1>
  bits<sz1> operator>>(const bits<sz1> data, const size_t shift) {
    return bits<sz1>::mk(data.v >> shift);
  }

  template<bitwidth sz1>
  bits<sz1> operator<<(const bits<sz1> data, const size_t shift) {
    return mask(bits<sz1>::mk(data.v << shift));
  }

  template<bitwidth sz1, bitwidth sz2>
  bits<sz1> operator>>(const bits<sz1> data, const bits<sz2> shift) {
    return bits<sz1>::mk(data.v >> shift.v);
  }

  template<bitwidth sz1, bitwidth sz2>
  bits<sz1> operator<<(const bits<sz1> data, const bits<sz2> shift) {
    return mask(bits<sz1>::mk(data.v << shift.v));
  }

  template<bitwidth sz>
  bits<1> operator==(const bits<sz> x, const bits<sz> y) {
    return bits<1>::mk(x.v == y.v);
  }

  template<typename T, size_t len>
  bits<1> operator==(const array<T, len> x, const array<T, len> y) {
    return bits<1>::mk(static_cast<const std::array<T, len>&>(x) ==
                       static_cast<const std::array<T, len>&>(y));
  }

  template<bitwidth sz>
  bits<1> operator!=(const bits<sz> x, const bits<sz> y) {
    return bits<1>::mk(x.v != y.v);;
  }

  template<bitwidth sz>
  bits<sz> operator+(const bits<sz> x, const bits<sz> y) {
    return mask(bits<sz>::mk(x.v + y.v));
  }

  template<bitwidth sz>
  bits<sz> operator-(const bits<sz> x, const bits<sz> y) {
    return mask(bits<sz>::mk(x.v + ~y.v + 1));
  }

  template<bitwidth sz>
  bits<1> operator<(const bits<sz> x, const bits<sz> y) {
    return bits<1>::mk(x.v < y.v);
  }

  template<bitwidth sz>
  bits<1> operator>(const bits<sz> x, const bits<sz> y) {
    return bits<1>::mk(x.v > y.v);
  }

  template<bitwidth sz>
  bits<1> operator<=(const bits<sz> x, const bits<sz> y) {
    return bits<1>::mk(x.v <= y.v);
  }

  template<bitwidth sz>
  bits<1> operator>=(const bits<sz> x, const bits<sz> y) {
    return bits<1>::mk(x.v >= y.v);
  }

  template<bitwidth sz>
  bits<1> slt(const bits<sz> x, const bits<sz> y) {
    return bits<1>::mk(x.to_shifted_sbits() < y.to_shifted_sbits());
  }

  template<bitwidth sz>
  bits<1> sgt(const bits<sz> x, const bits<sz> y) {
    return bits<1>::mk(x.to_shifted_sbits() > y.to_shifted_sbits());
  }

  template<bitwidth sz>
  bits<1> sle(const bits<sz> x, const bits<sz> y) {
    return bits<1>::mk(x.to_shifted_sbits() <= y.to_shifted_sbits());
  }

  template<bitwidth sz>
  bits<1> sge(const bits<sz> x, const bits<sz> y) {
    return bits<1>::mk(x.to_shifted_sbits() >= y.to_shifted_sbits());
  }

  template<bitwidth sz1, bitwidth sz2>
  bits<sz1 + sz2> concat(const bits<sz1> x, const bits<sz2> y) {
    return widen<sz1 + sz2>(x) << sz2 | widen<sz1 + sz2>(y);
  }

  template<bitwidth sz>
  bits<sz> operator~(const bits<sz> data) {
    return mask(bits<sz>::mk(~data.v));
  }

  template<bitwidth width, bitwidth sz>
  bits<std::max(sz, width)> sext(const bits<sz> x) {
    constexpr bitwidth newsz = std::max(sz, width);
    constexpr bitwidth nbits = width >= sz ? width - sz : bitwidth{0};
    return bits<newsz>::of_shifted_sbits((widen<newsz>(x) << nbits).to_shifted_sbits() >> nbits);
  }

  template<bitwidth width, bitwidth sz>
  bits<std::max(sz, width)> zextl(const bits<sz> x) {
    return widen<std::max(sz, width)>(x);
  }

  template<bitwidth width, bitwidth sz>
  bits<std::max(sz, width)> zextr(const bits<sz> x) {
    constexpr bitwidth mx = std::max(sz, width);
    return widen<mx>(x) << (mx - sz);
  }

  template<bitwidth times, bitwidth sz> struct repeat_t {
    static const bits<sz * times> v(bits<sz> bs) {
      return concat(repeat_t<times - 1, sz>::v(bs), bs);
    };
  };

  template<bitwidth sz> struct repeat_t<0, sz> {
    static const bits<0> v(bits<sz> /*unused*/) { return tt; };
  };

  template<bitwidth times> struct repeat_t<times, 1> {
    static const bits<times> v(bits<1> bs) { return sext<times>(bs); };
  };

  template<bitwidth sz> struct repeat_t<1, sz> {
    static constexpr auto v(bits<sz> bs) { return bs; }
  };

  template<bitwidth times, bitwidth sz>
  bits<sz * times> repeat(const bits<sz> bs) {
    return repeat_t<times, sz>::v(bs);
  }

  template<bitwidth idx, bitwidth width, bitwidth sz1>
  bits<width> slice(const bits<sz1> data) {
    return truncate<width>(data >> idx);
  }

  template<size_t pos, typename T, size_t len>
  array<T, len> replace(const array<T, len> arr, T val) {
    array<T, len> copy = arr;
    copy[pos] = val;
    return copy;
  }

  template<bitwidth sz>
  bits<sz>& bits<sz>::operator&=(const bits<sz> arg) { return (*this = *this & arg); }
  template<bitwidth sz>
  bits<sz>& bits<sz>::operator|=(const bits<sz> arg) { return (*this = *this | arg); }
  template<bitwidth sz>
  bits<sz>& bits<sz>::operator^=(const bits<sz> arg) { return (*this = *this ^ arg); }
  template<bitwidth sz>
  bits<sz>& bits<sz>::operator+=(const bits<sz> arg) { return (*this = *this + arg); }
  template<bitwidth sz>
  bits<sz>& bits<sz>::operator-=(const bits<sz> arg) { return (*this = *this - arg); }
  template<bitwidth sz>
  bits<sz>& bits<sz>::operator<<=(const size_t shift) { return (*this = *this << shift); }
  template<bitwidth sz>
  bits<sz>& bits<sz>::operator>>=(const size_t shift) { return (*this = *this >> shift); }
  template<bitwidth sz> template<bitwidth shift_sz>
  bits<sz>& bits<sz>::operator<<=(const bits<shift_sz> shift) { return (*this = *this << shift); }
  template<bitwidth sz> template<bitwidth shift_sz>
  bits<sz>& bits<sz>::operator>>=(const bits<shift_sz> shift) { return (*this = *this >> shift); }

  enum fmtstyle { full, hex, dec, bin };

  struct fmtopts {
    bool strings;
    bool newline;
    fmtstyle style;
  };

  static const _unused fmtopts default_fmtopts{ true, true, fmtstyle::full };

  template<typename T>
  static _unused _display_unoptimized unit display(const _unused T& msg,
                                                   const _unused fmtopts opts = default_fmtopts) {
#ifndef SIM_MINIMAL
    fmt(std::cout, msg, opts);
    std::cout << std::endl;
#endif
    return tt;
  }

#ifndef SIM_MINIMAL
  namespace internal {
    template<typename T, size_t len>
    std::string string_of_bytestring(const array<T, len>& val) {
      std::string s{};
      for (size_t pos = 0; pos < len; pos ++) {
        s.push_back(static_cast<char>(val[pos].v));
      }
      return s;
    }
  } // namespace internal
#endif

  template<size_t len>
  static _unused _display_unoptimized unit putstring(const _unused array<bits<8>, len>& msg) {
#ifndef SIM_MINIMAL
    std::cout << internal::string_of_bytestring(msg);
#endif
    return tt;
  }

  template<typename T>
  unit ignore(const T /*unused*/) {
    return tt;
  }

  /// Type info

  template<typename T> struct type_info;

  template<bitwidth sz> struct type_info<bits<sz>> {
    static constexpr bitwidth size = sz;
  };

  template<typename T, size_t len> struct type_info<array<T, len>> {
    static constexpr bitwidth size{len * type_info<T>::size};
  };

  /// Packing and unpacking

  // Forward-declared; our compiler defines one instance per struct and enum.
  // Unpack needs to be structs to get return-type polymorphism through explicit
  // template instantiation.  Pack is a struct to make overloading it easier.
  template<typename T, bitwidth sz> struct _unpack;
  template<typename T> static bits<type_info<T>::size> pack(const T val);

  template<typename T, bitwidth sz>
  static T unpack(const bits<sz>& bs) {
    return _unpack<T, sz>::unpack(bs);
  }

  /// Bits packing and unpacking (no-op, but needed by array packing/unpacking)

  template<bitwidth sz>
  static bits<sz> pack(const bits<sz> val) {
    return val;
  }

  template<bitwidth sz, bitwidth packed_sz>
  struct _unpack<bits<sz>, packed_sz> {
    static_assert(sz == packed_sz, "Inconsistent size parameters in call to unpack");
    static bits<sz> unpack(const bits<packed_sz> bs) {
      return bs;
    }
  };

  /// Array packing and unpacking

  template<typename T, size_t len>
  static bits<type_info<array<T, len>>::size> pack(const array<T, len>& val) {
    constexpr bitwidth elem_sz = type_info<T>::size;
    constexpr bitwidth packed_sz = type_info<array<T, len>>::size;
    bits<packed_sz> packed{};
    for (size_t pos = 0; pos < len; pos++) {
      packed <<= elem_sz;
      packed |= prims::widen<packed_sz>(val[pos]);
    }
    return packed;
  }

  template<typename T, size_t len, bitwidth packed_sz>
  struct _unpack<array<T, len>, packed_sz> {
    // We need a struct for return-type polymorphism
    static constexpr bitwidth elem_sz = type_info<T>::size;
    static constexpr bitwidth expected_sz = len * elem_sz;
    static_assert(expected_sz == packed_sz,
                  "Inconsistent size parameters in call to unpack");

    static array<T, len> unpack(bits<packed_sz> bs) { // not const&
      array<T, len> unpacked{};
      for (size_t pos = 0; pos < len; pos++) { // FIXME check the order of elements
        unpacked[len - 1 - pos] = prims::unpack<T>(truncate<elem_sz>(bs));
        bs >>= elem_sz;
      }
      return unpacked;
    }
  };

#ifndef SIM_MINIMAL
  // This convenience function creates a string from an object
  template<typename T>
  std::string repr(const T& val, const fmtopts opts = default_fmtopts) {
    std::ostringstream stream;
    fmt(stream, val, opts);
    return stream.str();
  }

  // This default overload passes a default set of format options
  template<typename T>
  std::ostream& fmt(std::ostream& os, const T& val) {
    return fmt(os, val, default_fmtopts);
  }

  /// Bits printing functions:

  enum class prefixes { sized, plain, minimal };

  namespace internal {
    template<bitwidth sz>
    static std::string decode_bitstring(bits<sz> val) {
      std::string s{};
      for (bitwidth pos = 0; pos < sz; pos += 8) {
        bits<8> c = prims::truncate<8>(val >> pos);
        s.push_back(static_cast<char>(c.v));
      }
      return s;
    }

    template<bitwidth sz>
    static std::ostream& bits_fmt(std::ostream& os, const bits<sz>& val,
                                  const fmtstyle style, const prefixes prefix) {
      if (prefix == prefixes::sized) {
        os << sz << "'";
      }

      switch (style) {
      case fmtstyle::bin:
        os << (prefix == prefixes::plain ? "0b" : "b");
        for (bitwidth pos = sz; pos > 0; pos--) {
          unsigned int bit = prims::truncate<1>(val >> (pos - 1u)).v;
          os << bit;
        }
        break;
      case fmtstyle::hex:
        os << (prefix == prefixes::plain ? "0x" : "x");
        os << std::hex << +val.v << std::dec;
        break;
      case fmtstyle::dec:
        os << std::dec << +val.v;
        break;
      case fmtstyle::full:
        if (sz <= 64) {
          bits_fmt(os, val, fmtstyle::bin, prefixes::minimal);
          os << " ("; bits_fmt(os, val, fmtstyle::hex, prefixes::plain);
          os << ", "; bits_fmt(os, val, fmtstyle::dec, prefixes::plain);
          os << ")";
        } else {
          bits_fmt(os, val, fmtstyle::hex, prefixes::minimal);
        }
        break;
      }
      return os;
    }
  } // namespace internal

  template<bitwidth sz>
  static std::ostream& fmt(std::ostream& os, const bits<sz>& val, const fmtopts opts) {
    return internal::bits_fmt(os, val, opts.style, prefixes::sized);
  }

  template<bitwidth sz>
  std::ostream& operator<<(std::ostream& os, const bits<sz>& bs) {
    return fmt(os, bs);
  }

  /// Array printing functions

  namespace internal {
    template<typename T>
    static std::ostream& array_fmt(std::ostream& os, const std::size_t len, const T* val, fmtopts opts) {
      if (opts.style == fmtstyle::full) {
        opts.style = fmtstyle::hex;
      }
      os << "[";
      if (len != 0) {
        fmt(os, val[0], opts);
        for (size_t pos = 1; pos < len; pos++) {
          os << "; ";
          fmt(os, val[pos], opts);
        }
      }
      os << "]";
      return os;
    }
  } // namespace internal

  template<typename T, size_t len>
  static std::ostream& fmt(std::ostream& os, const array<T, len>& val, const fmtopts opts) {
    return internal::array_fmt(os, len, val.data(), opts);
  }

  template<size_t len>
  static std::ostream& fmt(std::ostream& os, const array<bits<8>, len>& val, const fmtopts opts) {
    if (opts.strings) {
      os << "\"" << std::hex << std::setfill('0');
      for (size_t pos = 0; pos < len; pos ++) {
        unsigned char chr = static_cast<unsigned char>(val[pos].v);
        if (chr == '\\' || chr == '"') {
          os << "\\" << chr;
        } else if (std::isgraph(chr)) {
          os << chr;
        } else {
          os << "\\x" << std::setw(2) << static_cast<unsigned>(chr);
        }
      }
      os << "\"";
    } else {
      internal::array_fmt(os, len, val.data(), opts);
    }
    return os;
  }

  template<typename T, size_t len>
  std::ostream& operator<<(std::ostream& os, const array<T, len>& val) {
    return fmt(os, val);
  }

  namespace vcd {
    using namespace std::chrono;

    static _unused void header(std::ostream& os) {
      auto now = system_clock::to_time_t(system_clock::now());
      os << "$date " << std::ctime(&now) << " $end" << std::endl;
      os << "$version " << cuttlesim::version << " $end" << std::endl;
      os << "$timescale 1 ps $end" << std::endl;
    }

    static _unused void var(std::ostream& os, const std::string& name, const size_t sz) {
      os << "$var reg " << sz << " " << name << " " << name << " $end";
    }

    template<typename T>
    static _unused void dumpvar(std::ostream& os, std::string name, const T& val) {
      internal::bits_fmt(os, pack(val), fmtstyle::bin, prefixes::minimal);
      os << " " << name << std::endl;
    }
  }
#endif // #ifndef SIM_MINIMAL
} // namespace prims

using prims::array;
using prims::unit;
using prims::bits;
using namespace prims::literals;
namespace cuttlesim {
  struct reg_rwset {
    bool w0 : 1;

    bool may_read0(reg_rwset rL) {
      return !(rL.w0);
    }

    bool may_write0() {
      return !(w0);
    }

    void reset() {
      w0 = false;
    }

    reg_rwset() : w0{} {}
  };

  struct wire_rwset {
    bool r1 : 1;
    bool w0 : 1;

    static _unused bool may_read1(wire_rwset /*unused*/) {
      return true;
    }

    bool may_write0() {
      return !(r1 || w0);
    }

    void reset() {
      r1 = w0 = false;
    }

    wire_rwset() : r1{}, w0{} {}
  };

  struct ehr_rwset {
    bool r1 : 1; // FIXME does adding :1 always help?
    bool w0 : 1;
    bool w1 : 1;

    static _unused bool may_read0(ehr_rwset rL) {
      return !(rL.w1 || rL.w0);
    }

    static _unused bool may_read1(ehr_rwset rL) {
      return !(rL.w1);
    }

    bool may_write0() {
      return !(r1 || w0 || w1);
    }

    bool may_write1() {
      return !(w1);
    }

    void reset() {
      r1 = w0 = w1 = false;
    }

    // Removing this constructor causes Collatz's performance to drop 5x with GCC
    ehr_rwset() : r1{}, w0{}, w1{} {}
  };

  template<typename T, typename rwset>
  [[nodiscard]] bool read0(T* target, const T rL, rwset& rwl, const rwset rwL) {
    bool ok = rwl.may_read0(rwL);
    *target = rL;
    return ok;
  }

  template<typename T, typename rwset>
  [[nodiscard]] bool read1(T* target, const T rl, rwset& rwl, const rwset rwL) {
    bool ok = rwl.may_read1(rwL);
    *target = rl;
    rwl.r1 = true;
    return ok;
  }

  template<typename T, typename rwset>
  [[nodiscard]] bool write0(T& rl, const T val, rwset& rwl) {
    bool ok = rwl.may_write0();
    rl = val;
    rwl.w0 = true;
    return ok;
  }

  template<typename T, typename rwset>
  [[nodiscard]] bool write1(T& rl, const T val, rwset& rwl) {
    bool ok = rwl.may_write1();
    rl = val;
    rwl.w1 = true;
    return ok;
  }

  struct offsets {
    std::size_t state_offset;
    std::size_t state_sz;
    std::size_t rwset_offset;
    std::size_t rwset_sz;

    void memcpy(char* dst_state, char* src_state, char* dst_rwset, char* src_rwset) {
      std::memcpy(dst_rwset + rwset_offset, src_rwset + rwset_offset, rwset_sz);
      std::memcpy(dst_state + state_offset, src_state + state_offset, state_sz);
    }
  };

  template<typename T, int capacity>
  struct stack {
    int sz;
    unsigned: 0;
    T data[capacity];

    void push(T value) {
      data[sz++] = value;
    }

    stack() : sz{0} {}
  };

  using ull = unsigned long long int;
  template <typename simulator, typename... Args>
  _flatten _noinline typename simulator::state_t init_and_run(ull ncycles, Args&&... args) noexcept {
    return simulator(std::forward<Args>(args)...).run(ncycles).snapshot();
  }

#ifndef SIM_MINIMAL
  template<typename simulator, typename... Args>
  static  _noinline _unused void init_and_trace(std::string fname, ull ncycles, Args&&... args) {
    simulator(std::forward<Args>(args)...).trace(fname, ncycles, 1);
  }

  struct params {
    bool trace;
    std::string vcd_fpath;
    ull trace_period;
    ull ncycles;

    static params of_cli(int argc, char **argv) {
      params parsed = {
        .trace = false,
        .vcd_fpath = {},
        .trace_period = 0,
        .ncycles = 1000
      };

      if (argc > 1) {
        parsed.ncycles = std::stoull(argv[1]);
      }

      if (argc > 2) {
        parsed.trace = true;
        parsed.vcd_fpath = argv[2];
      }

      if (argc > 3) {
        parsed.trace_period = std::stoull(argv[3]);
      }

      return parsed;
    }
  };

  template<typename simulator, typename... Args>
  static _unused int main(int argc, char **argv, Args&&... args) {
    auto params = params::of_cli(argc, argv);

    // The original version of this code used a single ‘simulator’ and called
    // either ‘.trace’ or ‘.run’ on it; this made the code generated by both GCC
    // and clang about 10x slower.

    if (params.trace) {
      init_and_trace<simulator>(params.vcd_fpath, params.ncycles, std::forward<Args>(args)...);
    } else {
      init_and_run<simulator>(params.ncycles, std::forward<Args>(args)...).dump();
    }

    return 0;
  }
#endif
} // namespace cuttlesim

#define FAIL(rule_name) \
  { reset_##rule_name(); return false; }
#define FAIL_UNLESS(rule_name, can_fire) \
  { if (!(can_fire)) { FAIL(rule_name); } }
#define READ0(rule_name, reg, ptr) \
  FAIL_UNLESS(rule_name, read0((ptr), Log.state.reg, log.rwset.reg, Log.rwset.reg))
#define READ1(rule_name, reg, ptr) \
  FAIL_UNLESS(rule_name, read1((ptr), log.state.reg, log.rwset.reg, Log.rwset.reg))
#define WRITE0(rule_name, reg, val) \
  FAIL_UNLESS(rule_name, write0(log.state.reg, (val), log.rwset.reg))
#define WRITE1(rule_name, reg, val) \
  FAIL_UNLESS(rule_name, write1(log.state.reg, (val), log.rwset.reg))
#define COMMIT(rule_name) \
  (commit_##rule_name())

#define FAIL_DL(rule_name) \
  { dlog.apply(log, Log); return false; }
#define FAIL_UNLESS_DL(rule_name, can_fire) \
  { if (!(can_fire)) { FAIL_DL(rule_name); } }
#define READ0_DL(rule_name, reg, ptr) \
  { dlog.push(reg_name_t::reg); FAIL_UNLESS_DL(rule_name, read0((ptr), Log.state.reg, log.rwset.reg, Log.rwset.reg)) }
#define READ1_DL(rule_name, reg, ptr) \
  { dlog.push(reg_name_t::reg); FAIL_UNLESS_DL(rule_name, read1((ptr), log.state.reg, log.rwset.reg, Log.rwset.reg)) }
#define WRITE0_DL(rule_name, reg, val) \
  { dlog.push(reg_name_t::reg); FAIL_UNLESS_DL(rule_name, write0(log.state.reg, (val), log.rwset.reg)) }
#define WRITE1_DL(rule_name, reg, val) \
  { dlog.push(reg_name_t::reg); FAIL_UNLESS_DL(rule_name, write1(log.state.reg, (val), log.rwset.reg)) }
#define COMMIT_DL(rule_name) \
  dlog.apply(Log, log)

#define FAIL_DOL(rule_name) \
  { dlog.apply(log, Log); return false; }
#define FAIL_UNLESS_DOL(rule_name, can_fire) \
  { if (!(can_fire)) { FAIL_DOL(rule_name); } }
#define PUSH_DOL(reg) \
  dlog.push({ \
      offsetof(struct state_t, reg), sizeof(state_t::reg), \
      offsetof(struct rwset_t, reg), sizeof(rwset_t::reg), })
#define READ0_DOL(rule_name, reg, ptr) \
  { PUSH_DOL(reg); FAIL_UNLESS_DOL(rule_name, read0((ptr), Log.state.reg, log.rwset.reg, Log.rwset.reg)) }
#define READ1_DOL(rule_name, reg, ptr) \
  { PUSH_DOL(reg); FAIL_UNLESS_DOL(rule_name, read1((ptr), log.state.reg, log.rwset.reg, Log.rwset.reg)) }
#define WRITE0_DOL(rule_name, reg, val) \
  { PUSH_DOL(reg); FAIL_UNLESS_DOL(rule_name, write0(log.state.reg, (val), log.rwset.reg)) }
#define WRITE1_DOL(rule_name, reg, val) \
  { PUSH_DOL(reg); FAIL_UNLESS_DOL(rule_name, write1(log.state.reg, (val), log.rwset.reg)) }
#define COMMIT_DOL(rule_name) \
  dlog.apply(Log, log)

#undef _unlikely
#undef _unoptimized
#undef _display_unoptimized
#endif // #ifndef _PREAMBLE_HPP