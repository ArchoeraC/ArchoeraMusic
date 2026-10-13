// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:archoera_music/services/native_lib_paths.dart';
import 'package:archoera_music/services/search/indexer_ffi.dart';
import 'package:archoera_music/services/search/search_index.dart';
import 'package:archoera_music/services/search/search_models.dart';

/// indexer 原生冒烟测试（受保护：无 `.so` 时整体 skip）。
///
/// 覆盖：加载 indexer-ffi → 建临时 `library.db` fixture → `indexer_run` 全量 →
/// `indexer_analyze` → 经 [SearchIndex]（只读 `search.db`）查询命中（中文子串 /
/// 拼音 / 首字母）。
///
/// 定位共享库：dev 兜底 cwd=app/ → `app/core/indexer/build/indexer-ffi.so`。
void main() {
  final soPath = NativeLibPaths.resolve(NativeModule.indexer);
  final skip = soPath == null
      ? '未找到 indexer-ffi 共享库（先构建 app/core/indexer/build）'
      : false;

  test('indexer_analyze 与索引同构（中文 bigram / 拼音 / 首字母）', () {
    final lib = IndexerLibrary.load(soPath: soPath);
    final tokens = lib.analyze('我爱你');
    expect(tokens, isNotNull);
    expect(tokens!.lexical, contains('我爱'));
    expect(tokens.lexical, contains('爱你'));
    expect(tokens.pinyin, containsAll(const ['wo', 'ai', 'ni']));
    expect(tokens.initials, 'wan');

    // P4：查询侧连写全拼切分（woaini → wo ai ni）。
    final written = lib.analyze('woaini');
    expect(written, isNotNull);
    expect(written!.lexical, const ['woaini'], reason: '词法仍是整词');
    expect(written.pinyin, const ['wo', 'ai', 'ni'], reason: '拼音切为音节');
    // 英文不误切。
    expect(lib.analyze('hello')!.pinyin, const ['hello']);
  }, skip: skip);

  test('indexer_run 全量 + SearchIndex 查询命中', () async {
    final tmp = await Directory.systemTemp.createTemp('indexer_smoke');
    addTearDown(() => tmp.deleteSync(recursive: true));

    // 先加载库（预加载同目录 libe_sqlite3，统一进程 SQLite 实例）。
    final lib = IndexerLibrary.load(soPath: soPath);

    // 建最小 library.db fixture（仅 indexer 读取的列）。
    final libraryDb = '${tmp.path}/library.db';
    final searchDb = '${tmp.path}/search.db';
    final db = sqlite3.open(libraryDb);
    db.execute('''
      CREATE TABLE tracks (
        id TEXT PRIMARY KEY, path TEXT, title TEXT, artists TEXT,
        album TEXT, lyrics TEXT, file_mtime INTEGER
      )
    ''');
    db.execute('CREATE TABLE _scanner_meta (generation INTEGER)');
    db.execute('INSERT INTO _scanner_meta (generation) VALUES (7)');
    db.execute(
      'INSERT INTO tracks (id, path, title, artists, album, lyrics, file_mtime) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      [
        't1',
        '${tmp.path}/我爱你中国.mp3',
        '我爱你中国',
        jsonEncode([
          {'name': '群星'},
        ]),
        jsonEncode({'name': '红色经典'}),
        '我爱你中国',
        1700000000000,
      ],
    );
    db.close();

    // 全量构建（进度回调关闭：测试主 isolate 同步阻塞，回调无必要）。
    final (code, resultText) = lib.runBlocking(
      dbPath: libraryDb,
      indexPath: searchDb,
      full: true,
      onProgress: nullptr.cast<Void>(),
    );
    expect(code, 0, reason: 'indexer_run 应返回 0，实际: $resultText');
    final result =
        IndexerRunResult.fromJson(jsonDecode(resultText) as Map<String, dynamic>);
    expect(result.indexed, 1);
    expect(result.generation, 7);
    expect(File(searchDb).existsSync(), isTrue);

    // 只读打开 search.db，经原生分析器查询。
    final index = SearchIndex.open(searchDb, analyzer: lib.analyze);
    expect(index, isNotNull);
    addTearDown(index!.close);

    // 中文子串（歌词 / 标题）。
    final cn = index.search('中国');
    expect(cn.map((h) => h.trackId), contains('t1'));

    // 中文短语（P4：连续 bigram → 引号短语）仍命中标题「我爱你中国」。
    final phrase = index.search('我爱你');
    expect(phrase.map((h) => h.trackId), contains('t1'));

    // 拼音（音节以空格分隔 → 同构分析为音节 AND）。
    final py = index.search('wo ai ni');
    expect(py.map((h) => h.trackId), contains('t1'));

    // P4 连写全拼（无空格）：woaini 经原生分析器切为 wo/ai/ni → 命中。
    final pyWritten = index.search('woaini');
    expect(pyWritten.map((h) => h.trackId), contains('t1'));

    // 首字母前缀。
    final initials = index.search('wan');
    expect(initials.map((h) => h.trackId), contains('t1'));

    // 元数据范围：标题含「中国」，仍应命中。
    final meta = index.search('中国', scope: LocalSearchScope.metadata);
    expect(meta.map((h) => h.trackId), contains('t1'));
  }, skip: skip);

  test('两趟容错：精确命中即短路（不触发模糊）', () async {
    final lib = IndexerLibrary.load(soPath: soPath);
    final index = await _buildIndex(lib, const [('t1', 'Hello World')]);

    final hits = index.search('hello', fuzzy: true);
    expect(hits.map((h) => h.trackId), contains('t1'));
    expect(index.fuzzyQueries, 0, reason: '精确已命中，不应触发第二趟模糊');
  }, skip: skip);

  test('两趟容错：精确为空时模糊命中（拼写错字）', () async {
    final lib = IndexerLibrary.load(soPath: soPath);
    // 标题拼写错字 helo；查询为正确拼写 hello。
    final index = await _buildIndex(lib, const [('t1', 'Helo Song')]);

    // 单趟精确：错误拼写漏召回。
    expect(index.search('hello').map((h) => h.trackId), isEmpty);

    // 两趟：精确为空 → 编辑距离 ≤1 变体（helo）命中。
    final fuzzy = index.search('hello', fuzzy: true);
    expect(fuzzy.map((h) => h.trackId), contains('t1'));
    expect(index.fuzzyQueries, 1, reason: '精确为空应触发一次模糊查询');
  }, skip: skip);

  test('CJK 容错：拼音覆盖漏字 / 换位；第三趟兜底非同音错字', () async {
    final lib = IndexerLibrary.load(soPath: soPath);
    final index = await _buildIndex(lib, const [('t1', '周杰伦'), ('t2', '我爱你')]);

    // 漏字（周伦 ← 周杰伦）/ 换位（爱我 ← 我爱）：音节集合不变，拼音分支
    // （音节 AND、与位置无关）已覆盖 → 精确即命中，不触发第三趟。
    expect(index.search('周伦').map((h) => h.trackId), contains('t1'));
    expect(index.search('爱我').map((h) => h.trackId), contains('t2'));
    expect(index.cjkFuzzyQueries, 0, reason: '拼音分支覆盖漏字 / 换位，无需第三趟');

    // 非同音错字（周杰美：美「mei」不在文档）：精确为空 → 第三趟删除变体
    // （周杰）命中 t1。
    expect(index.search('周杰美').map((h) => h.trackId), isEmpty);
    final cjk = index.search('周杰美', fuzzy: true);
    expect(cjk.map((h) => h.trackId), contains('t1'));
    expect(index.cjkFuzzyQueries, 1, reason: '精确为空应触发一次 CJK 容错查询');

    // 多打一字（我爱美：美不在文档）：第三趟命中 t2。
    expect(index.search('我爱美').map((h) => h.trackId), isEmpty);
    expect(index.search('我爱美', fuzzy: true).map((h) => h.trackId),
        contains('t2'));

    // metadata 范围：第三趟对整条 OR 表达式施加列过滤，标题命中仍生效。
    final meta = index.search(
      '周杰美',
      scope: LocalSearchScope.metadata,
      fuzzy: true,
    );
    expect(meta.map((h) => h.trackId), contains('t1'));
  }, skip: skip);

  test('CJK 容错：精确命中即短路（不触发第三趟）', () async {
    final lib = IndexerLibrary.load(soPath: soPath);
    final index = await _buildIndex(lib, const [('t1', '周杰伦')]);

    final hits = index.search('周杰伦', fuzzy: true);
    expect(hits.map((h) => h.trackId), contains('t1'));
    expect(index.cjkFuzzyQueries, 0, reason: '精确已命中，不应触发 CJK 容错');
  }, skip: skip);

  test('CJK 容错：纯拉丁查询不触发第三趟（走第二趟）', () async {
    final lib = IndexerLibrary.load(soPath: soPath);
    final index = await _buildIndex(lib, const [('t1', 'Helo Song')]);

    final hits = index.search('hello', fuzzy: true);
    expect(hits.map((h) => h.trackId), contains('t1'));
    expect(index.cjkFuzzyQueries, 0, reason: '无 CJK 不应触发第三趟');
    expect(index.fuzzyQueries, 1, reason: '应走拉丁第二趟');
  }, skip: skip);

  test('T1 跨语言：analyze defs 双向（love→爱、爱→love）', () {
    final lib = IndexerLibrary.load(soPath: soPath);

    final love = lib.analyze('love');
    expect(love, isNotNull);
    expect(love!.crossLingual, contains('爱'), reason: 'love 的候选汉字含 爱');
    // 词法 / 拼音 / 首字母三列不受跨语言候选影响。
    expect(love.lexical, const ['love']);

    final ai = lib.analyze('爱');
    expect(ai, isNotNull);
    expect(ai!.crossLingual, contains('love'), reason: '爱 的英文释义含 love');
    expect(ai.lexical, contains('爱'));

    // 无释义词：defs 为空。
    expect(lib.analyze('zzzznotaword')!.crossLingual, isEmpty);
  }, skip: skip);

  test('T1 跨语言召回：英文查询命中含「爱」的中文歌；中文查询命中含 love 的英文内容',
      () async {
    final lib = IndexerLibrary.load(soPath: soPath);
    final index = await _buildIndex(lib, const [
      ('t1', '爱'), // 中文标题含 爱
      ('t2', 'Love Story'), // 英文标题含 love
    ]);

    // 英文 → 候选汉字 爱 → 命中中文 t1。
    expect(index.search('love').map((h) => h.trackId), contains('t1'));
    // 中文 → 候选英文 love → 命中英文 t2。
    expect(index.search('爱').map((h) => h.trackId), contains('t2'));
  }, skip: skip);

  test('T0 双语 .lrc：英文译文可被英文查询命中、罗马音命中音译行', () async {
    final lib = IndexerLibrary.load(soPath: soPath);
    final tmp = await Directory.systemTemp.createTemp('indexer_lrc_layer');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final libraryDb = '${tmp.path}/library.db';
    final searchDb = '${tmp.path}/search.db';
    final db = sqlite3.open(libraryDb);
    db.execute('''
      CREATE TABLE tracks (
        id TEXT PRIMARY KEY, path TEXT, title TEXT, artists TEXT,
        album TEXT, lyrics TEXT, file_mtime INTEGER
      )
    ''');
    db.execute('CREATE TABLE _scanner_meta (generation INTEGER)');
    db.execute('INSERT INTO _scanner_meta (generation) VALUES (1)');
    db.execute(
      'INSERT INTO tracks (id, path, title, artists, album, lyrics, file_mtime) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      ['tL', '${tmp.path}/dual.mp3', '中文歌', '[]', null, null, 1],
    );
    db.close();
    // 同时间戳 3 行：原文 / 英文译文 / 罗马音。
    File('${tmp.path}/dual.lrc').writeAsStringSync(
        '[00:01.00]你好世界\n[00:01.00]hello world\n[00:01.00]ni hao shi jie\n');

    final (code, text) = lib.runBlocking(
      dbPath: libraryDb,
      indexPath: searchDb,
      full: true,
      optionsJson: jsonEncode({'index_lrc': true, 'pinyin': true}),
      onProgress: nullptr.cast<Void>(),
    );
    expect(code, 0, reason: 'indexer_run 应返回 0，实际: $text');

    final index = SearchIndex.open(searchDb, analyzer: lib.analyze);
    expect(index, isNotNull);
    addTearDown(index!.close);

    // 英文查询命中译文行（lyrics_tr_tok）。
    expect(index.search('hello').map((h) => h.trackId), contains('tL'));
    // 罗马音查询命中音译行（lyrics_rom_tok）。
    expect(index.search('ni hao').map((h) => h.trackId), contains('tL'));
    // 中文原文仍命中（原文不回退）。
    expect(index.search('你好').map((h) => h.trackId), contains('tL'));
  }, skip: skip);
}

/// 建最小 `library.db` fixture 并跑全量 indexer，返回只读 [SearchIndex]。
///
/// [tracks] 为 `(id, title)` 列表；曲库 / 索引落在临时目录，随测试结束清理。
Future<SearchIndex> _buildIndex(
  IndexerLibrary lib,
  List<(String, String)> tracks,
) async {
  final tmp = await Directory.systemTemp.createTemp('indexer_fuzzy');
  addTearDown(() => tmp.deleteSync(recursive: true));

  final libraryDb = '${tmp.path}/library.db';
  final searchDb = '${tmp.path}/search.db';
  final db = sqlite3.open(libraryDb);
  db.execute('''
    CREATE TABLE tracks (
      id TEXT PRIMARY KEY, path TEXT, title TEXT, artists TEXT,
      album TEXT, lyrics TEXT, file_mtime INTEGER
    )
  ''');
  db.execute('CREATE TABLE _scanner_meta (generation INTEGER)');
  db.execute('INSERT INTO _scanner_meta (generation) VALUES (1)');
  for (final (id, title) in tracks) {
    db.execute(
      'INSERT INTO tracks (id, path, title, artists, album, lyrics, file_mtime) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      [id, '${tmp.path}/$id.mp3', title, '[]', null, null, 1],
    );
  }
  db.close();

  final (code, text) = lib.runBlocking(
    dbPath: libraryDb,
    indexPath: searchDb,
    full: true,
    onProgress: nullptr.cast<Void>(),
  );
  expect(code, 0, reason: 'indexer_run 应返回 0，实际: $text');

  final index = SearchIndex.open(searchDb, analyzer: lib.analyze);
  expect(index, isNotNull);
  addTearDown(index!.close);
  return index;
}
