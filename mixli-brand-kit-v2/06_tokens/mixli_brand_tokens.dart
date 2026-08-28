// Mixli v2 brand tokens. Keep product chrome restrained.
import 'package:flutter/material.dart';
abstract final class MixliBrand {
 static const ink = Color(0xFF0F1B41); static const play = Color(0xFFFF736D); static const learn = Color(0xFFB76DF3); static const transform = Color(0xFF7D82F4); static const become = Color(0xFF25C5F4);
 static const lightCanvas=Color(0xFFF8FAFF), lightSurface=Color(0xFFFFFFFF), lightText2=Color(0xFF596581), lightBorder=Color(0xFFDEE5F2);
 static const darkCanvas=Color(0xFF070D20), darkSurface=Color(0xFF0C1430), darkText=Color(0xFFF7F9FF), darkText2=Color(0xFFAAB5CC), darkBorder=Color(0xFF26304A);
 static const journey = LinearGradient(begin:Alignment.topLeft,end:Alignment.bottomRight,colors:[play,Color(0xFFF776A4),learn,transform,Color(0xFF43BDF8),become],stops:[0,.22,.47,.66,.85,1]);
}
