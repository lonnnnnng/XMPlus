// Ported from xmly/catalogue.py (AGPL-3.0-or-later).
import '../models/xmly_models.dart';
import 'xmly_client.dart';

class XmlyCatalogue {
  final XmlyClient client;
  XmlyCatalogue(this.client);
  static const _digits = {'零': 0, '〇': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4, '五': 5, '六': 6, '七': 7, '八': 8, '九': 9};
  static const _units = {'十': 10, '百': 100, '千': 1000, '万': 10000};
  static const _token = r'[0-9零〇一二两三四五六七八九十百千万]+';
  static int episodeNumber(Object? value) {
    final match = RegExp('^(?:第\\s*)?($_token)(?:\\s*[集章节回期部])?\$').firstMatch('$value'.trim());
    if (match == null) throw const XmlyException('invalid_episode', '请输入正整数或中文集数', definitive: true);
    final token = match[1]!;
    int result;
    if (RegExp(r'^[0-9]+$').hasMatch(token)) {
      result = int.tryParse(token) ?? 0;
    } else if (token.split('').every(_digits.containsKey)) {
      result = int.tryParse(token.split('').map((char) => _digits[char]).join()) ?? 0;
    } else {
      result = 0;
      var section = 0, digit = 0;
      for (final char in token.split('')) {
        if (_digits.containsKey(char)) { digit = _digits[char]!; }
        else if (_units.containsKey(char)) {
          final unit = _units[char]!;
          if (unit == 10000) { result += (section + digit) * unit; section = digit = 0; }
          else { section += (digit == 0 ? 1 : digit) * unit; digit = 0; }
        } else { throw const XmlyException('invalid_episode', '集数格式无效', definitive: true); }
      }
      result += section + digit;
    }
    if (result < 1 || result > 5000) throw const XmlyException('invalid_episode', '集数范围为 1 到 5000', definitive: true);
    return result;
  }
  static int? titleEpisode(Track track) {
    final match = RegExp('第\\s*($_token)\\s*[集章节回期部]').firstMatch(track.title) ??
      RegExp('^\\s*($_token)(?:\\s*[集章节回期部]|[\\s.、:：_\\-]|\$)').firstMatch(track.title);
    if (match != null) { try { return episodeNumber(match[1]); } on XmlyException { return null; } }
    return null;
  }
  static int? _itemOrder(Track track) {
    for (final value in [track.orderNo, track.raw['order_no'], track.raw['orderNo'], track.raw['orderNum'], track.raw['sequence'], track.raw['index'], track.episode]) {
      try { return episodeNumber(value); } on XmlyException { /* Try the next original ordinal field. */ }
    }
    return null;
  }
  static Track selectEpisode(List<Track> items, Object episode) {
    final number = episodeNumber(episode);
    for (final parse in const [titleEpisode, _itemOrder]) {
      var hasEpisodes = false;
      Track? match;
      for (final item in items) {
        final value = parse(item);
        if (value == null) continue;
        hasEpisodes = true;
        if (value != number) continue;
        if (match != null) throw const XmlyException('ambiguous_episode', '该集数对应多个声音，请直接选择声音', definitive: true);
        match = item;
      }
      if (match != null) return match;
      // Official ordinals are a fallback only if no title supplies an episode.
      if (hasEpisodes) break;
    }
    throw const XmlyException('episode_not_found', '专辑中没有找到该集', definitive: true);
  }
  Future<List<Track>> album(String albumId, {int pageSize = xmlyAlbumPageSize}) async {
    if (!RegExp(r'^[1-9][0-9]{0,18}$').hasMatch(albumId)) throw const XmlyException('invalid_id', '专辑 ID 必须是正整数', definitive: true);
    if (pageSize < 1 || pageSize > xmlyAlbumPageSize) throw const XmlyException('invalid_page', '专辑每页数量无效', definitive: true);
    int? expectedTotal;
    Future<AlbumPage> livePage(int page) async {
      final result = await client.album(albumId, page: page, pageSize: pageSize, ascending: true);
      if (result.total > 5000) throw const XmlyException('catalogue_limit', '专辑超过 5000 首队列上限', definitive: true);
      if (result.total < 0 || result.page != page || result.pageSize != pageSize || result.album.id != albumId) {
        throw const XmlyException('invalid_catalogue', '专辑分页无效');
      }
      expectedTotal ??= result.total;
      if (expectedTotal != result.total) throw const XmlyException('catalogue_changed', '专辑内容发生变化，请刷新重试');
      final offset = (page - 1) * pageSize;
      if (result.tracks.length != (result.total - offset).clamp(0, pageSize)) {
        throw const XmlyException('incomplete_catalogue', '专辑分页不完整，请刷新重试');
      }
      _checkTracks(result.tracks, albumId, offset);
      return result;
    }
    // A matching historical tail cannot prove that earlier chapters or titles
    // are current. Full search and range selection need every live page.
    final first = await livePage(1);
    final total = first.total;
    if (total == 0) return const <Track>[];
    final lastPage = (total + pageSize - 1) ~/ pageSize;
    final values = <Track>[
      ...first.tracks,
      for (var page = 2; page <= lastPage; page++) ...(await livePage(page)).tracks,
    ];
    if (values.length != total) throw const XmlyException('incomplete_catalogue', '专辑分页不完整，请刷新重试');
    _checkTracks(values, albumId, 0);
    // Official ascending positions, never a UI-sorted list index, are the fallback.
    values.sort((a, b) => (a.orderNo ?? a.officialPosition ?? 0).compareTo(b.orderNo ?? b.officialPosition ?? 0));
    return List.unmodifiable(values);
  }
  static void _checkTracks(List<Track> tracks, String albumId, int offset) {
    final identifiers = <String>{};
    for (var index = 0; index < tracks.length; index++) {
      final track = tracks[index];
      xmlyIdentifier(track.id);
      if (track.albumId != albumId) throw const XmlyException('id_mismatch', '专辑包含其他专辑的声音');
      if (track.officialPosition != offset + index + 1) throw const XmlyException('incomplete_catalogue', '专辑声音顺序无效，请刷新重试');
      if (!identifiers.add(track.id)) throw const XmlyException('duplicate_page', '专辑声音重复，请刷新重试');
    }
  }
  static List<Track> selectRange(List<Track> items, String expression) {
    if (items.length > 5000 || expression.isEmpty || expression.length > 40000) throw const XmlyException('invalid_range', '选择范围无效', definitive: true);
    final wanted = <int>{};
    for (final part in expression.split(RegExp('[,，]'))) {
      final match = RegExp(r'^\s*([0-9]+)\s*(?:-\s*([0-9]+)\s*)?$').firstMatch(part);
      if (match == null) throw const XmlyException('invalid_range', '请使用 1-1000 或 1,3,5-10 的格式', definitive: true);
      final start = int.tryParse(match[1]!) ?? 0, end = int.tryParse(match[2] ?? match[1]!) ?? 0;
      if (start < 1 || end < start || end > 5000) throw const XmlyException('invalid_range', '选择范围必须在 1 到 5000 之间', definitive: true);
      for (var value = start; value <= end; value++) { wanted.add(value); }
    }
    final selected = <int, Track>{};
    for (final item in items) {
      final number = item.orderNo ?? item.officialPosition;
      if (number == null || !wanted.contains(number)) continue;
      if (selected.containsKey(number) && selected[number]!.id != item.id) throw const XmlyException('ambiguous_episode', '官方序号重复，请直接选择声音', definitive: true);
      selected[number] = item;
    }
    if (selected.length != wanted.length) throw const XmlyException('range_not_found', '部分序号不存在，请检查专辑范围', definitive: true);
    final numbers = selected.keys.toList()..sort();
    return List.unmodifiable(numbers.map((number) => selected[number]!));
  }
}
