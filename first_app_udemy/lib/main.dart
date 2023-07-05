import 'package:flutter/material.dart';
import 'package:first_app_udemy/gradient_container.dart';

void main() {
  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: GradientContainer(Colors.lightBlue, Colors.deepOrange),
      ),
    ),
  ); // runApp
}
