import 'package:flutter/material.dart';

import '../../../app/theme.dart';

const categoryIcons = <String, (String, IconData)>{
  'work': ('Work', Icons.work_outline),
  'laptop': ('Laptop', Icons.laptop_outlined),
  'store': ('Store', Icons.storefront_outlined),
  'trending_up': ('Growth', Icons.trending_up),
  'gift': ('Gift', Icons.card_giftcard_outlined),
  'wallet': ('Wallet', Icons.account_balance_wallet_outlined),
  'restaurant': ('Dining', Icons.restaurant_outlined),
  'car': ('Transport', Icons.directions_car_outlined),
  'shopping_bag': ('Shopping', Icons.shopping_bag_outlined),
  'home': ('Home', Icons.home_outlined),
  'bolt': ('Utilities', Icons.bolt_outlined),
  'graduation_cap': ('Education', Icons.school_outlined),
  'medical': ('Health', Icons.medical_services_outlined),
  'movie': ('Entertainment', Icons.movie_outlined),
  'flight': ('Travel', Icons.flight_outlined),
  'category': ('General', Icons.category_outlined),
};

const categoryColors = <String, String>{
  '#D4AF37': 'Gold',
  '#E8D5A3': 'Champagne',
  '#C4B5FD': 'Lavender',
  '#FBBF24': 'Amber',
  '#4ADE80': 'Mint',
  '#F9A8D4': 'Rose',
  '#FDBA74': 'Peach',
  '#93C5FD': 'Sky',
  '#FCA5A5': 'Coral',
  '#A5F3FC': 'Ice',
};

Color categoryColor(String hex) {
  if (!RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(hex)) return AppColors.gold;
  return Color(0xff000000 | int.parse(hex.substring(1), radix: 16));
}

class CategoryBadge extends StatelessWidget {
  const CategoryBadge(this.icon, this.hex, {super.key});
  final String icon, hex;

  @override
  Widget build(BuildContext context) {
    final color = categoryColor(hex);
    return ExcludeSemantics(
      child: Container(
        height: 42,
        width: 42,
        decoration: BoxDecoration(
          color: color,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
        child: Icon(
          categoryIcons[icon]?.$2 ?? Icons.category_outlined,
          size: 22,
          color: color.computeLuminance() > .179
              ? AppColors.midnight
              : AppColors.text,
        ),
      ),
    );
  }
}
