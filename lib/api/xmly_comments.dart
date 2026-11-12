import '../models/xmly_models.dart';
import 'xmly_client.dart';

class TrackComment {
  const TrackComment({
    required this.id,
    required this.author,
    required this.content,
    required this.createdAt,
    required this.likes,
    required this.replyCount,
    this.parentAuthor = '',
  });

  final String id, author, content, createdAt, parentAuthor;
  final int likes, replyCount;
}

class TrackCommentPage {
  TrackCommentPage({
    required List<TrackComment> comments,
    required this.total,
    required this.hasMore,
  }) : comments = List.unmodifiable(comments);

  final List<TrackComment> comments;
  final int total;
  final bool hasMore;
}

/// Public reading endpoints used by the official sound page. Never sends cookies.
class XmlyComments {
  XmlyComments(this.client);
  final XmlyClient client;

  static const _invalid = XmlyException('invalid_comments', '评论列表格式无效，请重试');

  static int _count(Object? value) {
    if (value is! int || value < 0) throw _invalid;
    return value;
  }

  static String _text(Object? value) => value is String ? value : '';

  Future<TrackCommentPage> load(
    String trackId, {
    int page = 1,
    String? commentId,
  }) async {
    if (page < 1 || page > 250) {
      throw const XmlyException('comment_limit', '最多读取 5000 条评论，请刷新后查看');
    }
    final response = await client.request(
      'GET',
      XmlyClient.searchOrigin,
      commentId == null
          ? '/revision/comment/queryComments'
          : '/revision/comment/queryReplies',
      query: {
        'trackId': xmlyIdentifier(trackId),
        if (commentId != null) 'commentId': xmlyIdentifier(commentId),
        'page': page,
        'pageSize': 20,
      },
      account: false,
    );
    final data = xmlyMap(response['data']);
    if (_count(data['currentPage']) != page) throw _invalid;
    final total = _count(data['totalComment']);
    final pages = _count(data['totalPage']);
    final raw = data[commentId == null ? 'comments' : 'replies'];
    if (raw is! List || raw.length > 20) throw _invalid;
    final comments = <TrackComment>[];
    final ids = <String>{};
    for (final value in raw) {
      final row = xmlyMap(value);
      final rawId = row['id'];
      if (rawId is! int && rawId is! String) throw _invalid;
      final id = xmlyIdentifier(rawId.toString());
      if (!ids.add(id) || row['content'] is! String) throw _invalid;
      comments.add(
        TrackComment(
          id: id,
          author: _text(row['nickname']),
          content: row['content'] as String,
          createdAt: _text(row['createAt']),
          likes: _count(row['likes'] ?? 0),
          replyCount: _count(row['replyCount'] ?? 0),
          parentAuthor: _text(row['parentNickname']),
        ),
      );
    }
    return TrackCommentPage(
      comments: comments,
      total: total,
      hasMore: page < pages,
    );
  }
}
