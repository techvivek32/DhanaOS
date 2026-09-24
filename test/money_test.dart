import 'package:dhanaos/core/money.dart';
import 'package:flutter_test/flutter_test.dart';

/// D-004. Money is the one place a rounding slip turns into a wrong invoice, so the
/// arithmetic and the GST split are pinned here rather than trusted.
void main() {
  group('Money arithmetic', () {
    test('holds exact minor units, never a float', () {
      const a = Money.inr(485000); // ₹4,850.00
      const b = Money.inr(15050); //   ₹150.50
      expect((a + b).minor, 500050);
      expect((a - b).minor, 469950);
    });

    test('parses operator input with separators', () {
      expect(Money.parse('4,850.50', 'INR').minor, 485050);
      expect(Money.parse('₹ 1,00,000', 'INR').minor, 10000000);
      expect(Money.parse('', 'INR').minor, 0);
    });

    test('multiplication rounds rather than truncating', () {
      // 5 × ₹1,250.00 = ₹6,250.00 — the one derived total the mockups got right.
      expect((const Money.inr(125000) * 5).minor, 625000);
      // A third of a paisa must not silently vanish downward.
      expect((const Money.inr(100) * 0.335).minor, 34);
    });

    test('refuses to mix currencies', () {
      expect(
        () => const Money.inr(100) + const Money.usd(100),
        throwsArgumentError,
      );
    });

    test('formats INR with Indian digit grouping', () {
      // 48,50,000 — not 4,850,000. This is the bug every western-default formatter has.
      final formatted = const Money.inr(485000000).format();
      expect(formatted, contains('48,50,000'));
      expect(formatted, contains('₹'));
    });

    test('formats USD with western grouping', () {
      expect(const Money.usd(485000).format(), contains('4,850'));
    });
  });

  group('GST', () {
    const taxable = Money.inr(100000); // ₹1,000.00

    test('intrastate splits into CGST and SGST', () {
      final g = GstBreakdown.on(taxable, ratePct: GstRates.jewellery, interstate: false);
      expect(g.igst.minor, 0);
      expect(g.cgst.minor + g.sgst.minor, 3000); // 3% of ₹1,000 = ₹30.00
      expect(g.total.minor, 103000);
    });

    test('interstate is all IGST', () {
      final g = GstBreakdown.on(taxable, ratePct: GstRates.jewellery, interstate: true);
      expect(g.cgst.minor, 0);
      expect(g.sgst.minor, 0);
      expect(g.igst.minor, 3000);
    });

    test('an odd paisa lands in CGST so the parts always sum to the whole', () {
      // 3% of ₹3.33 = 9.99 paise -> 10 paise, which cannot split evenly.
      final g = GstBreakdown.on(const Money.inr(333), ratePct: 3, interstate: false);
      expect(g.cgst.minor + g.sgst.minor, g.tax.minor);
      expect(g.taxable + g.tax, g.total);
    });

    test('rate follows the cost category', () {
      expect(GstRates.forCategory('metal'), GstRates.jewellery);
      expect(GstRates.forCategory('setting'), GstRates.makingCharges);
      expect(GstRates.forCategory('certification'), GstRates.services);
    });
  });
}
