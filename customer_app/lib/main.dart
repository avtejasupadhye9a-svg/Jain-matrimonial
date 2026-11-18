// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:jain_client/jain_client.dart';

import 'customer_home.dart';

void main() => runApp(CustomerApp(api: Api()));

class CustomerApp extends StatelessWidget {
  const CustomerApp({super.key, required this.api});
  final Api api;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Jain Matrimonial',
    theme: jainTheme(),
    home: SessionGate(
      api: api,
      role: 'customer',
      home: (_) => CustomerHome(api: api),
    ),
  );
}
