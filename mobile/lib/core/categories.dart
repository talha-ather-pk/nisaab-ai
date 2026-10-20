import 'package:flutter/material.dart';

/// Keep in sync with CATEGORIES in backend/nlp_engine.py.
const List<String> kAllCategories = [
  'Groceries', 'Food & Dining', 'Transport', 'Fuel', 'Utilities',
  'Mobile & Internet', 'Shopping', 'Health', 'Education', 'Entertainment',
  'Rent', 'Charity', 'Transfers', 'Salary', 'Freelance', 'Other',
];
const List<String> kIncomeCategories = ['Salary', 'Freelance', 'Transfers', 'Other'];
final List<String> kExpenseCategories =
    kAllCategories.where((c) => c != 'Salary' && c != 'Freelance').toList(growable: false);

List<String> categoriesFor(String type) => type == 'income' ? kIncomeCategories : kExpenseCategories;

/// Category identity: icon + hue. The hue is only ever shown next to the category name.
class CategoryStyle {
  final IconData icon;
  final Color color;
  const CategoryStyle(this.icon, this.color);

  static const Map<String, CategoryStyle> _styles = {
    'Groceries': CategoryStyle(Icons.shopping_cart_outlined, Color(0xFF2E9E5B)),
    'Food & Dining': CategoryStyle(Icons.restaurant_outlined, Color(0xFFE07A2F)),
    'Transport': CategoryStyle(Icons.directions_car_outlined, Color(0xFF3A7BD5)),
    'Fuel': CategoryStyle(Icons.local_gas_station_outlined, Color(0xFF8A5CD6)),
    'Utilities': CategoryStyle(Icons.bolt_outlined, Color(0xFFD9922A)),
    'Mobile & Internet': CategoryStyle(Icons.wifi, Color(0xFF1FA2B8)),
    'Shopping': CategoryStyle(Icons.shopping_bag_outlined, Color(0xFFD6457A)),
    'Health': CategoryStyle(Icons.local_hospital_outlined, Color(0xFFD64545)),
    'Education': CategoryStyle(Icons.school_outlined, Color(0xFF4B5BD6)),
    'Entertainment': CategoryStyle(Icons.movie_outlined, Color(0xFFB8459A)),
    'Rent': CategoryStyle(Icons.home_outlined, Color(0xFF6B7A90)),
    'Charity': CategoryStyle(Icons.volunteer_activism_outlined, Color(0xFF2E9E8E)),
    'Transfers': CategoryStyle(Icons.swap_horiz, Color(0xFF5A6B85)),
    'Salary': CategoryStyle(Icons.payments_outlined, Color(0xFF2E9E5B)),
    'Freelance': CategoryStyle(Icons.laptop_mac_outlined, Color(0xFF2E9E5B)),
    'Other': CategoryStyle(Icons.category_outlined, Color(0xFF6B7A90)),
  };

  static CategoryStyle of(String category) => _styles[category] ?? _styles['Other']!;
}
