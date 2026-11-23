import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Colours taken 1:1 from the website's Tailwind classes.
class AppColors {
  AppColors._();

  // Brand greens
  static const green = Color(0xFF238869); // primary buttons, accents
  static const greenHover = Color(0xFF1F775D);
  static const greenDeep = Color(0xFF228466); // "Show all" buttons, badges
  static const greenText = Color(0xFF207E61); // "View all" links
  static const greenSearch = Color(0xFF33846C); // hero search button
  static const greenFocus = Color(0xFF40A587);
  static const greenPrice = Color(0xFF2C8360);
  static const greenListing = Color(0xFF319A7A); // listing page accent
  static const greenSoft = Color(0xFF4FBE9F); // avatar bubble
  static const forest = Color(0xFF1A3A2E); // headings, footer
  static const forestDark = Color(0xFF112A22); // hero headline
  static const forestListing = Color(0xFF1E4636); // listing headings
  static const forestLogin = Color(0xFF163C2E);
  static const hostForest = Color(0xFF1E3E2B); // host workspace sidebar
  static const hostGold = Color(0xFFDFBA73); // host workspace accent

  // Surfaces
  static const cream = Color(0xFFFFFEF9); // page background
  static const mint = Color(0xFFF4FBF8); // icon tiles, UK Stay Hub savings card
  static const mintPill = Color(0xFFE9F3F0);
  static const mintBorder = Color(0xFFC5E1D8);
  static const fieldBg = Color(0xFFF7FAF8);
  static const fieldBorder = Color(0xFFDCEAE5);
  static const inputBorder = Color(0xFFD9DEDB);
  static const rangeBg = Color(0xFFD2F8E8);
  static const rangeText = Color(0xFF173F32);
  static const hostBg = Color(0xFFFAFAFA);
  static const neutral50 = Color(0xFFFAFAFA);
  static const neutral100 = Color(0xFFF5F5F5);
  static const neutral200 = Color(0xFFE5E5E5);
  static const neutral300 = Color(0xFFD4D4D4);
  static const neutral400 = Color(0xFFA3A3A3);
  static const neutral500 = Color(0xFF737373);
  static const neutral600 = Color(0xFF525252);
  static const neutral700 = Color(0xFF404040);
  static const neutral800 = Color(0xFF262626);
  static const neutral900 = Color(0xFF171717);

  // Text
  static const slate = Color(0xFF64748B); // body copy
  static const slateDark = Color(0xFF4A5568);
  static const muted = Color(0xFF64776F);
  static const mutedGreen = Color(0xFF4A5D54);
  static const textDark = Color(0xFF1E2423);
  static const star = Color(0xFFFFB800);
  static const yellowStar = Color(0xFFEAB308);
  static const red = Color(0xFFDC2626);
  static const amber = Color(0xFFF59E0B);
}

/// The site's Tailwind breakpoints: sm 640, md 768, lg 1024, xl 1280.
extension Breakpoints on BuildContext {
  double get vw => MediaQuery.sizeOf(this).width;
  bool get sm => vw >= 640;
  bool get md => vw >= 768;
  bool get lg => vw >= 1024;
  bool get xl => vw >= 1280;
}

/// Typography: Fraunces for display, Inter for UI, DM Sans for prices/pills –
/// exactly the three families the site loads.
class AppText {
  AppText._();

  static TextStyle fraunces({
    double size = 16,
    FontWeight weight = FontWeight.w700,
    Color color = AppColors.forest,
    FontStyle style = FontStyle.normal,
    double? height,
    double? letterSpacing,
  }) =>
      GoogleFonts.fraunces(
        fontSize: size,
        fontWeight: weight,
        color: color,
        fontStyle: style,
        height: height,
        letterSpacing: letterSpacing,
      );

  static TextStyle inter({
    double size = 14,
    FontWeight weight = FontWeight.w400,
    Color color = AppColors.forest,
    double? height,
    double? letterSpacing,
    TextDecoration? decoration,
  }) =>
      GoogleFonts.inter(
        fontSize: size,
        fontWeight: weight,
        color: color,
        height: height,
        letterSpacing: letterSpacing,
        decoration: decoration,
      );

  static TextStyle dmSans({
    double size = 14,
    FontWeight weight = FontWeight.w500,
    Color color = AppColors.forest,
    double? height,
  }) =>
      GoogleFonts.dmSans(fontSize: size, fontWeight: weight, color: color, height: height);

  /// Section titles: `text-3xl font-bold font-fraunces text-[#1A3A2E]`.
  static TextStyle get sectionTitle => fraunces(size: 30, height: 1.15);

  /// Section subtitles: `text-[#64748B] font-inter text-lg`.
  static TextStyle get sectionSubtitle => inter(size: 17, color: AppColors.slate, height: 1.5);
}

ThemeData buildTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.green,
      primary: AppColors.green,
      surface: Colors.white,
    ),
    scaffoldBackgroundColor: AppColors.cream,
    splashFactory: InkRipple.splashFactory,
  );
  return base.copyWith(
    textTheme: GoogleFonts.interTextTheme(base.textTheme).apply(
      bodyColor: AppColors.forest,
      displayColor: AppColors.forest,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.cream,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      foregroundColor: AppColors.forest,
      titleTextStyle: AppText.fraunces(size: 20),
    ),
    dividerTheme: const DividerThemeData(color: AppColors.neutral200, thickness: 1, space: 1),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xFF121212),
      contentTextStyle: AppText.inter(size: 14, color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    // MenuBar.js backdrop: bg-black/30.
    drawerTheme: const DrawerThemeData(scrimColor: Color(0x4D000000)),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      hintStyle: AppText.inter(size: 15, color: AppColors.neutral400),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.inputBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.inputBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.green, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.red),
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? AppColors.green : Colors.transparent,
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.all(Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? AppColors.green : AppColors.neutral300,
      ),
    ),
  );
}
