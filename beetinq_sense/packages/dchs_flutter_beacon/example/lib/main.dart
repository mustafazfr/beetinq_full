// ignore_for_file: prefer_const_declarations

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import './controller/requirement_state_controller.dart';
import './view/home_page.dart';

void main() {
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    Get.put(RequirementStateController());

    final themeData = Theme.of(context);
    final primary = Colors.blue;

    return GetMaterialApp(
      theme: ThemeData(
        brightness: Brightness.light,
        primarySwatch: primary,
        appBarTheme: themeData.appBarTheme.copyWith(
          elevation: 0.5,
          color: Colors.white,
          actionsIconTheme: themeData.primaryIconTheme.copyWith(
            color: primary,
          ),
          iconTheme: themeData.primaryIconTheme.copyWith(
            color: primary,
          ),
        ),
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: primary,
      ),
      home: const HomePage(),
    );
  }
}
