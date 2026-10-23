Vendored from https://github.com/ggerganov/ggwave
Commit: 060aec73dd7123ccac200442f75bdc7369795ffe (2026-04-16)
License: MIT (see LICENSE). Reed-Solomon: MIT (see src/reed-solomon/LICENSE).

Local modifications (src/reed-solomon/rs.hpp and poly.hpp):
- DecodeBlock: abort decoding when FindErrorLocator reports more errors than can be corrected
  (upstream ignores the return value and continues with a stale locator).
- DecodeBlock: refuse to append found errors when they would overflow the erasure polynomial.
- FindErrors: stop when the error polynomial is full instead of appending past its size.
- Poly::Append (poly.hpp): return false when full instead of asserting and writing past the buffer.
Without these, an uncorrectable codeword (for example a strong message decoded with the wrong
fixed length) can write past the polynomial buffers: assert abort in debug, memory corruption in release.
All other files are unmodified.
