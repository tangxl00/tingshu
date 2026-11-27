import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/up_user.dart';

/// 关注的 UP 主（本地持久化）：关注后可在「我的」里直达，只听 TA 的内容
class FollowStore extends ChangeNotifier {
  FollowStore._();
  static final FollowStore instance = FollowStore._();

  static const _key = 'tingyou_follows';

  final List<UpUser> _list = [];

  List<UpUser> get list => List.unmodifiable(_list);

  int get length => _list.length;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    try {
      final arr = jsonDecode(raw) as List;
      _list
        ..clear()
        ..addAll(arr.map(
            (e) => UpUser.fromJson((e as Map).cast<String, dynamic>())));
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(_list.map((u) => u.toJson()).toList()),
    );
  }

  bool isFollowing(int mid) => _list.any((u) => u.mid == mid);

  UpUser? byMid(int mid) {
    for (final u in _list) {
      if (u.mid == mid) return u;
    }
    return null;
  }

  /// 关注 / 取消关注，返回切换后的状态（true=已关注）
  Future<bool> toggle(UpUser user) async {
    if (user.mid == 0) return false;
    final i = _list.indexWhere((u) => u.mid == user.mid);
    if (i >= 0) {
      _list.removeAt(i);
    } else {
      _list.insert(0, user);
    }
    notifyListeners();
    await _save();
    return i < 0;
  }

  Future<void> remove(int mid) async {
    _list.removeWhere((u) => u.mid == mid);
    notifyListeners();
    await _save();
  }
}