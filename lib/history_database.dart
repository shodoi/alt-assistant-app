import 'dart:async';
import 'dart:typed_data';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'config.dart';

class HistoryItem {
  final int? id;
  final String altText;
  final Uint8List thumbnail;
  final Uint8List? fullImage; // Added for resumption
  final String? messagesJson; // Added for resumption (JSON string)
  final DateTime createdAt;

  HistoryItem({
    this.id,
    required this.altText,
    required this.thumbnail,
    this.fullImage,
    this.messagesJson,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'altText': altText,
      'thumbnail': thumbnail,
      'fullImage': fullImage,
      'messagesJson': messagesJson,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory HistoryItem.fromMap(Map<String, dynamic> map) {
    return HistoryItem(
      id: map['id'],
      altText: map['altText'],
      thumbnail: map['thumbnail'],
      fullImage: map['fullImage'],
      messagesJson: map['messagesJson'],
      createdAt: DateTime.parse(map['createdAt']),
    );
  }
}

class HistoryDatabase {
  static final HistoryDatabase instance = HistoryDatabase._init();
  static Database? _database;

  HistoryDatabase._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('history.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 2, // Incremented version
      onCreate: _createDB,
      onUpgrade: _upgradeDB,
    );
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        altText TEXT NOT NULL,
        thumbnail BLOB NOT NULL,
        fullImage BLOB,
        messagesJson TEXT,
        createdAt TEXT NOT NULL
      )
    ''');
  }

  Future _upgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE history ADD COLUMN fullImage BLOB');
      await db.execute('ALTER TABLE history ADD COLUMN messagesJson TEXT');
    }
  }

  Future<int> insert(HistoryItem item) async {
    final db = await instance.database;
    final id = await db.insert('history', item.toMap());
    
    // Keep only latest 30 items (Reduced from 50)
    await _deleteOldItems();
    
    return id;
  }

  Future<List<HistoryItem>> getAllHistory() async {
    final db = await instance.database;
    final result = await db.query('history', orderBy: 'createdAt DESC');

    return result.map((json) => HistoryItem.fromMap(json)).toList();
  }

  Future<void> _deleteOldItems() async {
    final db = await instance.database;
    // Get the ID of the 30th newest item
    final result = await db.query(
      'history',
      orderBy: 'createdAt DESC',
      limit: 1,
      offset: AppConfig.historyLimit - 1, // Change from 49 to 29
    );

    if (result.isNotEmpty) {
      final lastId = result.first['id'] as int;
      await db.delete(
        'history',
        where: 'id < ?',
        whereArgs: [lastId],
      );
    }
  }

  Future<int> update(HistoryItem item) async {
    final db = await instance.database;
    return await db.update(
      'history',
      item.toMap(),
      where: 'id = ?',
      whereArgs: [item.id],
    );
  }

  Future<void> delete(int id) async {
    final db = await instance.database;
    await db.delete(
      'history',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future close() async {
    final db = await instance.database;
    db.close();
  }
}
