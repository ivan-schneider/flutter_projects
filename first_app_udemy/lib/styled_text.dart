import 'package:flutter/material.dart';

class StyledText extends StatelessWidget {
  const StyledText({super.key});

  @override
  Widget build(context) {
    return const Text(
      'BERTOLO',
      style: TextStyle(
        color: Color.fromARGB(255, 230, 173, 3),
        fontSize: 28,
        fontWeight: FontWeight.bold,
      ),
    );
  }
}
