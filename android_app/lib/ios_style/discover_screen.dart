import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'album_screen.dart';
import 'models.dart';
import 'source_registry.dart';
import 'source_router.dart';
import 'storage.dart';
import 'widgets.dart';

class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();

  String _source = SourceRegistry.tingyou;
  String _categoryId = 'recommend';
  List<AppAlbum> _albums = [];
  bool _loading = false;
  bool _hasMore = false;
  String? _error;

  bool _searchMode = false;
  List<AppAlbum> _results = [];
  List<String> _failedSources = [];
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  List<String> get _browseSources {
    final store = context.read<LocalStore>();
    final result = <String>[SourceRegistry.tingyou];
    if (store.isSourceEnabled(SourceRegistry.bili)) {
      result.add(SourceRegistry.bili);
    }
    return result;
  }

  Future<void> _load({bool refresh = true}) async {
    if (_loading) return;
    if (refresh) {
      setState(() {
        _loading = true;
        _error = null;
        _albums = [];
      });
    } else {
      setState(() => _loading = true);
    }
    try {
      final router = context.read<SourceRouter>();
      final page = refresh ? 1 : (_albums.length ~/ 20) + 1;
      final result = await router.discoverCategory(
        _source,
        _categoryId,
        page: page,
      );
      if (!mounted) return;
      setState(() {
        _albums = refresh ? result.items : [..._albums, ...result.items];
        _hasMore = result.hasMore;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _switchSource(String source) {
    if (source == _source) return;
    final categories = DiscoverCatalog.categories(source);
    setState(() {
      _source = source;
      _categoryId = categories.isEmpty ? '' : categories.first.id;
      _searchMode = false;
      _results = [];
    });
    _load();
  }

  Future<void> _search({bool initial = true}) async {
    final keyword = _controller.text.trim();
    if (keyword.isEmpty) return;
    final store = context.read<LocalStore>();
    if (initial) {
      await store.addSearchHistory(keyword);
      setState(() {
        _searchMode = true;
        _searching = true;
        _results = [];
        _failedSources = [];
      });
    }
    final enabled = store.enabledSearchSources();
    if (enabled.isEmpty) {
      setState(() {
        _searching = false;
        _failedSources = ['没有可用音源'];
      });
      return;
    }
    final router = context.read<SourceRouter>();
    final outcome = await router.aggregateSearch(
      keyword,
      enabled,
      onPartial: (partial) {
        if (!mounted) return;
        setState(() {
          _results = partial.albums;
          _failedSources = partial.failedSources;
        });
      },
    );
    if (!mounted) return;
    setState(() {
      _results = outcome.albums;
      _failedSources = outcome.failedSources;
      _searching = false;
    });
  }

  void _exitSearch() {
    _controller.clear();
    _focus.unfocus();
    setState(() {
      _searchMode = false;
      _results = [];
      _failedSources = [];
    });
  }

  void _openAlbum(AppAlbum album) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AlbumScreen(album: album),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<LocalStore>();
    final browseSources = _browseSources;
    if (!browseSources.contains(_source)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _switchSource(browseSources.first));
    }
    final categories = DiscoverCatalog.categories(_source);
    final showHistory = _focus.hasFocus &&
        _controller.text.trim().isEmpty &&
        !_searchMode;

    return Scaffold(
      appBar: AppBar(
        // v2.0.1：顶部留白减半（toolbarHeight 56→28）
        toolbarHeight: 28,
        title: const Text(''),
        backgroundColor: Theme.of(context).colorScheme.surface,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Padding(
                    padding: EdgeInsets.only(left: 10),
                    child: Icon(Icons.search, size: 20),
                  ),
                  Expanded(
                    child: TextField(
                      key: const ValueKey('discover_search_field'),
                      controller: _controller,
                      focusNode: _focus,
                      textInputAction: TextInputAction.search,
                      decoration: const InputDecoration(
                        hintText: '搜索书名 / 作者 / 主播',
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(horizontal: 10),
                      ),
                      onSubmitted: (_) => _search(),
                    ),
                  ),
                  if (_controller.text.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.cancel),
                      onPressed: _exitSearch,
                    ),
                ],
              ),
            ),
          ),
          if (showHistory) _historySection(store),
          if (_searchMode)
            Expanded(child: _searchResults())
          else
            Expanded(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: Row(
                      children: [
                        PopupMenuButton<String>(
                          onSelected: _switchSource,
                          itemBuilder: (_) => browseSources
                              .map((s) => PopupMenuItem<String>(
                                    value: s,
                                    child: Text(SourceRegistry.displayName(s)),
                                  ))
                              .toList(),
                          child: Row(
                            children: [
                              Text('音源：${SourceRegistry.displayName(_source)}',
                                  style: const TextStyle(fontSize: 14)),
                              const Icon(Icons.expand_more, size: 16),
                            ],
                          ),
                        ),
                        Expanded(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: categories.map((c) {
                                final selected = c.id == _categoryId;
                                return TextButton(
                                  onPressed: () {
                                    setState(() => _categoryId = c.id);
                                    _load();
                                  },
                                  child: Text(
                                    c.name,
                                    style: TextStyle(
                                      fontWeight: selected
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                      color: selected
                                          ? Theme.of(context).colorScheme.primary
                                          : Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant,
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(child: _libraryList()),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _historySection(LocalStore store) {
    final history = store.searchHistory;
    if (history.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('最近搜索', style: Theme.of(context).textTheme.labelLarge),
              const Spacer(),
              TextButton(
                onPressed: store.clearSearchHistory,
                child: const Text('清空'),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: history.map((kw) {
              return InputChip(
                label: Text(kw),
                onPressed: () {
                  _controller.text = kw;
                  _search();
                },
                onDeleted: () => store.removeSearchHistory(kw),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _searchResults() {
    if (_searching && _results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_results.isEmpty) {
      return EmptyView(
        icon: Icons.search_off,
        title: '没有找到「${_controller.text}」相关的有声书',
        message: _failedSources.isEmpty
            ? null
            : '以下音源本次搜索不可用：${_failedSources.join('、')}',
      );
    }
    return ListView.builder(
      itemCount: _results.length + (_failedSources.isEmpty ? 0 : 1),
      itemBuilder: (context, index) {
        if (index == 0 && _failedSources.isNotEmpty) {
          return Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              '以下音源本次搜索不可用：${_failedSources.join('、')}',
              style: const TextStyle(fontSize: 12, color: Colors.orange),
            ),
          );
        }
        final album = _results[index - (_failedSources.isEmpty ? 0 : 1)];
        return _albumRow(album, index);
      },
    );
  }

  Widget _libraryList() {
    if (_loading && _albums.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _albums.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            TextButton(onPressed: () => _load(), child: const Text('重试')),
          ],
        ),
      );
    }
    if (_albums.isEmpty) {
      return const EmptyView(icon: Icons.auto_stories, title: '暂无内容');
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollEndNotification &&
            notification.metrics.extentAfter < 200 &&
            _hasMore &&
            !_loading) {
          _load(refresh: false);
        }
        return false;
      },
      child: ListView.builder(
        itemCount: _albums.length + 1,
        itemBuilder: (context, index) {
          if (index == _albums.length) {
            if (_loading) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            return const SizedBox(height: 16);
          }
          return _albumRow(_albums[index], index);
        },
      ),
    );
  }

  Widget _albumRow(AppAlbum album, int index) {
    return ListTile(
      key: ValueKey(index == 0 && _searchMode
          ? 'discover_search_row_0'
          : 'discover_album_row_$index'),
      leading: CoverImage(url: album.coverUrl, size: 64),
      title: Text(album.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          if (album.author != null) album.author!,
          if (album.chapterCount != null) '${album.chapterCount}集',
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => _openAlbum(album),
    );
  }
}
