// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'drift_database.dart';

// ignore_for_file: type=lint
class $NotebooksTable extends Notebooks
    with TableInfo<$NotebooksTable, NotebookRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $NotebooksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _versionMeta = const VerificationMeta(
    'version',
  );
  @override
  late final GeneratedColumn<int> version = GeneratedColumn<int>(
    'version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deviceIdMeta = const VerificationMeta(
    'deviceId',
  );
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
    'device_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<DateTime> deletedAt = GeneratedColumn<DateTime>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _parentIdMeta = const VerificationMeta(
    'parentId',
  );
  @override
  late final GeneratedColumn<String> parentId = GeneratedColumn<String>(
    'parent_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sortOrderMeta = const VerificationMeta(
    'sortOrder',
  );
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
    'sort_order',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    version,
    updatedAt,
    deviceId,
    deletedAt,
    name,
    parentId,
    sortOrder,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'notebooks';
  @override
  VerificationContext validateIntegrity(
    Insertable<NotebookRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('version')) {
      context.handle(
        _versionMeta,
        version.isAcceptableOrUnknown(data['version']!, _versionMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('device_id')) {
      context.handle(
        _deviceIdMeta,
        deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_deviceIdMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('parent_id')) {
      context.handle(
        _parentIdMeta,
        parentId.isAcceptableOrUnknown(data['parent_id']!, _parentIdMeta),
      );
    }
    if (data.containsKey('sort_order')) {
      context.handle(
        _sortOrderMeta,
        sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  NotebookRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return NotebookRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      version: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}version'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      deviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}device_id'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}deleted_at'],
      ),
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      parentId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}parent_id'],
      ),
      sortOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_order'],
      )!,
    );
  }

  @override
  $NotebooksTable createAlias(String alias) {
    return $NotebooksTable(attachedDatabase, alias);
  }
}

class NotebookRow extends DataClass implements Insertable<NotebookRow> {
  /// ULID 主键。
  final String id;

  /// 本地递增版本号，服务端接管后用于 LWW 冲突判定。
  final int version;
  final DateTime updatedAt;

  /// 产生该次变更的设备，用于同步自回声过滤。
  final String deviceId;

  /// tombstone 软删除：非空即删除，删除靠它传播，不物理删（§11）。
  final DateTime? deletedAt;
  final String name;
  final String? parentId;
  final int sortOrder;
  const NotebookRow({
    required this.id,
    required this.version,
    required this.updatedAt,
    required this.deviceId,
    this.deletedAt,
    required this.name,
    this.parentId,
    required this.sortOrder,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['version'] = Variable<int>(version);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    map['device_id'] = Variable<String>(deviceId);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<DateTime>(deletedAt);
    }
    map['name'] = Variable<String>(name);
    if (!nullToAbsent || parentId != null) {
      map['parent_id'] = Variable<String>(parentId);
    }
    map['sort_order'] = Variable<int>(sortOrder);
    return map;
  }

  NotebooksCompanion toCompanion(bool nullToAbsent) {
    return NotebooksCompanion(
      id: Value(id),
      version: Value(version),
      updatedAt: Value(updatedAt),
      deviceId: Value(deviceId),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
      name: Value(name),
      parentId: parentId == null && nullToAbsent
          ? const Value.absent()
          : Value(parentId),
      sortOrder: Value(sortOrder),
    );
  }

  factory NotebookRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return NotebookRow(
      id: serializer.fromJson<String>(json['id']),
      version: serializer.fromJson<int>(json['version']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      deviceId: serializer.fromJson<String>(json['deviceId']),
      deletedAt: serializer.fromJson<DateTime?>(json['deletedAt']),
      name: serializer.fromJson<String>(json['name']),
      parentId: serializer.fromJson<String?>(json['parentId']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'version': serializer.toJson<int>(version),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'deviceId': serializer.toJson<String>(deviceId),
      'deletedAt': serializer.toJson<DateTime?>(deletedAt),
      'name': serializer.toJson<String>(name),
      'parentId': serializer.toJson<String?>(parentId),
      'sortOrder': serializer.toJson<int>(sortOrder),
    };
  }

  NotebookRow copyWith({
    String? id,
    int? version,
    DateTime? updatedAt,
    String? deviceId,
    Value<DateTime?> deletedAt = const Value.absent(),
    String? name,
    Value<String?> parentId = const Value.absent(),
    int? sortOrder,
  }) => NotebookRow(
    id: id ?? this.id,
    version: version ?? this.version,
    updatedAt: updatedAt ?? this.updatedAt,
    deviceId: deviceId ?? this.deviceId,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
    name: name ?? this.name,
    parentId: parentId.present ? parentId.value : this.parentId,
    sortOrder: sortOrder ?? this.sortOrder,
  );
  NotebookRow copyWithCompanion(NotebooksCompanion data) {
    return NotebookRow(
      id: data.id.present ? data.id.value : this.id,
      version: data.version.present ? data.version.value : this.version,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      name: data.name.present ? data.name.value : this.name,
      parentId: data.parentId.present ? data.parentId.value : this.parentId,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
    );
  }

  @override
  String toString() {
    return (StringBuffer('NotebookRow(')
          ..write('id: $id, ')
          ..write('version: $version, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deviceId: $deviceId, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('name: $name, ')
          ..write('parentId: $parentId, ')
          ..write('sortOrder: $sortOrder')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    version,
    updatedAt,
    deviceId,
    deletedAt,
    name,
    parentId,
    sortOrder,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NotebookRow &&
          other.id == this.id &&
          other.version == this.version &&
          other.updatedAt == this.updatedAt &&
          other.deviceId == this.deviceId &&
          other.deletedAt == this.deletedAt &&
          other.name == this.name &&
          other.parentId == this.parentId &&
          other.sortOrder == this.sortOrder);
}

class NotebooksCompanion extends UpdateCompanion<NotebookRow> {
  final Value<String> id;
  final Value<int> version;
  final Value<DateTime> updatedAt;
  final Value<String> deviceId;
  final Value<DateTime?> deletedAt;
  final Value<String> name;
  final Value<String?> parentId;
  final Value<int> sortOrder;
  final Value<int> rowid;
  const NotebooksCompanion({
    this.id = const Value.absent(),
    this.version = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.name = const Value.absent(),
    this.parentId = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  NotebooksCompanion.insert({
    required String id,
    this.version = const Value.absent(),
    required DateTime updatedAt,
    required String deviceId,
    this.deletedAt = const Value.absent(),
    required String name,
    this.parentId = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       updatedAt = Value(updatedAt),
       deviceId = Value(deviceId),
       name = Value(name);
  static Insertable<NotebookRow> custom({
    Expression<String>? id,
    Expression<int>? version,
    Expression<DateTime>? updatedAt,
    Expression<String>? deviceId,
    Expression<DateTime>? deletedAt,
    Expression<String>? name,
    Expression<String>? parentId,
    Expression<int>? sortOrder,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (version != null) 'version': version,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deviceId != null) 'device_id': deviceId,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (name != null) 'name': name,
      if (parentId != null) 'parent_id': parentId,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (rowid != null) 'rowid': rowid,
    });
  }

  NotebooksCompanion copyWith({
    Value<String>? id,
    Value<int>? version,
    Value<DateTime>? updatedAt,
    Value<String>? deviceId,
    Value<DateTime?>? deletedAt,
    Value<String>? name,
    Value<String?>? parentId,
    Value<int>? sortOrder,
    Value<int>? rowid,
  }) {
    return NotebooksCompanion(
      id: id ?? this.id,
      version: version ?? this.version,
      updatedAt: updatedAt ?? this.updatedAt,
      deviceId: deviceId ?? this.deviceId,
      deletedAt: deletedAt ?? this.deletedAt,
      name: name ?? this.name,
      parentId: parentId ?? this.parentId,
      sortOrder: sortOrder ?? this.sortOrder,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (version.present) {
      map['version'] = Variable<int>(version.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (deviceId.present) {
      map['device_id'] = Variable<String>(deviceId.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<DateTime>(deletedAt.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (parentId.present) {
      map['parent_id'] = Variable<String>(parentId.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('NotebooksCompanion(')
          ..write('id: $id, ')
          ..write('version: $version, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deviceId: $deviceId, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('name: $name, ')
          ..write('parentId: $parentId, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $NotesTable extends Notes with TableInfo<$NotesTable, NoteRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $NotesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _versionMeta = const VerificationMeta(
    'version',
  );
  @override
  late final GeneratedColumn<int> version = GeneratedColumn<int>(
    'version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deviceIdMeta = const VerificationMeta(
    'deviceId',
  );
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
    'device_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<DateTime> deletedAt = GeneratedColumn<DateTime>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _notebookIdMeta = const VerificationMeta(
    'notebookId',
  );
  @override
  late final GeneratedColumn<String> notebookId = GeneratedColumn<String>(
    'notebook_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _contentMdMeta = const VerificationMeta(
    'contentMd',
  );
  @override
  late final GeneratedColumn<String> contentMd = GeneratedColumn<String>(
    'content_md',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _contentHashMeta = const VerificationMeta(
    'contentHash',
  );
  @override
  late final GeneratedColumn<String> contentHash = GeneratedColumn<String>(
    'content_hash',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    version,
    updatedAt,
    deviceId,
    deletedAt,
    notebookId,
    title,
    contentMd,
    contentHash,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'notes';
  @override
  VerificationContext validateIntegrity(
    Insertable<NoteRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('version')) {
      context.handle(
        _versionMeta,
        version.isAcceptableOrUnknown(data['version']!, _versionMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('device_id')) {
      context.handle(
        _deviceIdMeta,
        deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_deviceIdMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    if (data.containsKey('notebook_id')) {
      context.handle(
        _notebookIdMeta,
        notebookId.isAcceptableOrUnknown(data['notebook_id']!, _notebookIdMeta),
      );
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    }
    if (data.containsKey('content_md')) {
      context.handle(
        _contentMdMeta,
        contentMd.isAcceptableOrUnknown(data['content_md']!, _contentMdMeta),
      );
    }
    if (data.containsKey('content_hash')) {
      context.handle(
        _contentHashMeta,
        contentHash.isAcceptableOrUnknown(
          data['content_hash']!,
          _contentHashMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  NoteRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return NoteRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      version: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}version'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      deviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}device_id'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}deleted_at'],
      ),
      notebookId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}notebook_id'],
      ),
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      contentMd: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content_md'],
      )!,
      contentHash: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content_hash'],
      )!,
    );
  }

  @override
  $NotesTable createAlias(String alias) {
    return $NotesTable(attachedDatabase, alias);
  }
}

class NoteRow extends DataClass implements Insertable<NoteRow> {
  /// ULID 主键。
  final String id;

  /// 本地递增版本号，服务端接管后用于 LWW 冲突判定。
  final int version;
  final DateTime updatedAt;

  /// 产生该次变更的设备，用于同步自回声过滤。
  final String deviceId;

  /// tombstone 软删除：非空即删除，删除靠它传播，不物理删（§11）。
  final DateTime? deletedAt;
  final String? notebookId;
  final String title;
  final String contentMd;

  /// 内容哈希，用于快速判断是否有实质变更 / 同步校验和。
  final String contentHash;
  const NoteRow({
    required this.id,
    required this.version,
    required this.updatedAt,
    required this.deviceId,
    this.deletedAt,
    this.notebookId,
    required this.title,
    required this.contentMd,
    required this.contentHash,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['version'] = Variable<int>(version);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    map['device_id'] = Variable<String>(deviceId);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<DateTime>(deletedAt);
    }
    if (!nullToAbsent || notebookId != null) {
      map['notebook_id'] = Variable<String>(notebookId);
    }
    map['title'] = Variable<String>(title);
    map['content_md'] = Variable<String>(contentMd);
    map['content_hash'] = Variable<String>(contentHash);
    return map;
  }

  NotesCompanion toCompanion(bool nullToAbsent) {
    return NotesCompanion(
      id: Value(id),
      version: Value(version),
      updatedAt: Value(updatedAt),
      deviceId: Value(deviceId),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
      notebookId: notebookId == null && nullToAbsent
          ? const Value.absent()
          : Value(notebookId),
      title: Value(title),
      contentMd: Value(contentMd),
      contentHash: Value(contentHash),
    );
  }

  factory NoteRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return NoteRow(
      id: serializer.fromJson<String>(json['id']),
      version: serializer.fromJson<int>(json['version']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      deviceId: serializer.fromJson<String>(json['deviceId']),
      deletedAt: serializer.fromJson<DateTime?>(json['deletedAt']),
      notebookId: serializer.fromJson<String?>(json['notebookId']),
      title: serializer.fromJson<String>(json['title']),
      contentMd: serializer.fromJson<String>(json['contentMd']),
      contentHash: serializer.fromJson<String>(json['contentHash']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'version': serializer.toJson<int>(version),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'deviceId': serializer.toJson<String>(deviceId),
      'deletedAt': serializer.toJson<DateTime?>(deletedAt),
      'notebookId': serializer.toJson<String?>(notebookId),
      'title': serializer.toJson<String>(title),
      'contentMd': serializer.toJson<String>(contentMd),
      'contentHash': serializer.toJson<String>(contentHash),
    };
  }

  NoteRow copyWith({
    String? id,
    int? version,
    DateTime? updatedAt,
    String? deviceId,
    Value<DateTime?> deletedAt = const Value.absent(),
    Value<String?> notebookId = const Value.absent(),
    String? title,
    String? contentMd,
    String? contentHash,
  }) => NoteRow(
    id: id ?? this.id,
    version: version ?? this.version,
    updatedAt: updatedAt ?? this.updatedAt,
    deviceId: deviceId ?? this.deviceId,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
    notebookId: notebookId.present ? notebookId.value : this.notebookId,
    title: title ?? this.title,
    contentMd: contentMd ?? this.contentMd,
    contentHash: contentHash ?? this.contentHash,
  );
  NoteRow copyWithCompanion(NotesCompanion data) {
    return NoteRow(
      id: data.id.present ? data.id.value : this.id,
      version: data.version.present ? data.version.value : this.version,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      notebookId: data.notebookId.present
          ? data.notebookId.value
          : this.notebookId,
      title: data.title.present ? data.title.value : this.title,
      contentMd: data.contentMd.present ? data.contentMd.value : this.contentMd,
      contentHash: data.contentHash.present
          ? data.contentHash.value
          : this.contentHash,
    );
  }

  @override
  String toString() {
    return (StringBuffer('NoteRow(')
          ..write('id: $id, ')
          ..write('version: $version, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deviceId: $deviceId, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('notebookId: $notebookId, ')
          ..write('title: $title, ')
          ..write('contentMd: $contentMd, ')
          ..write('contentHash: $contentHash')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    version,
    updatedAt,
    deviceId,
    deletedAt,
    notebookId,
    title,
    contentMd,
    contentHash,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NoteRow &&
          other.id == this.id &&
          other.version == this.version &&
          other.updatedAt == this.updatedAt &&
          other.deviceId == this.deviceId &&
          other.deletedAt == this.deletedAt &&
          other.notebookId == this.notebookId &&
          other.title == this.title &&
          other.contentMd == this.contentMd &&
          other.contentHash == this.contentHash);
}

class NotesCompanion extends UpdateCompanion<NoteRow> {
  final Value<String> id;
  final Value<int> version;
  final Value<DateTime> updatedAt;
  final Value<String> deviceId;
  final Value<DateTime?> deletedAt;
  final Value<String?> notebookId;
  final Value<String> title;
  final Value<String> contentMd;
  final Value<String> contentHash;
  final Value<int> rowid;
  const NotesCompanion({
    this.id = const Value.absent(),
    this.version = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.notebookId = const Value.absent(),
    this.title = const Value.absent(),
    this.contentMd = const Value.absent(),
    this.contentHash = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  NotesCompanion.insert({
    required String id,
    this.version = const Value.absent(),
    required DateTime updatedAt,
    required String deviceId,
    this.deletedAt = const Value.absent(),
    this.notebookId = const Value.absent(),
    this.title = const Value.absent(),
    this.contentMd = const Value.absent(),
    this.contentHash = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       updatedAt = Value(updatedAt),
       deviceId = Value(deviceId);
  static Insertable<NoteRow> custom({
    Expression<String>? id,
    Expression<int>? version,
    Expression<DateTime>? updatedAt,
    Expression<String>? deviceId,
    Expression<DateTime>? deletedAt,
    Expression<String>? notebookId,
    Expression<String>? title,
    Expression<String>? contentMd,
    Expression<String>? contentHash,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (version != null) 'version': version,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deviceId != null) 'device_id': deviceId,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (notebookId != null) 'notebook_id': notebookId,
      if (title != null) 'title': title,
      if (contentMd != null) 'content_md': contentMd,
      if (contentHash != null) 'content_hash': contentHash,
      if (rowid != null) 'rowid': rowid,
    });
  }

  NotesCompanion copyWith({
    Value<String>? id,
    Value<int>? version,
    Value<DateTime>? updatedAt,
    Value<String>? deviceId,
    Value<DateTime?>? deletedAt,
    Value<String?>? notebookId,
    Value<String>? title,
    Value<String>? contentMd,
    Value<String>? contentHash,
    Value<int>? rowid,
  }) {
    return NotesCompanion(
      id: id ?? this.id,
      version: version ?? this.version,
      updatedAt: updatedAt ?? this.updatedAt,
      deviceId: deviceId ?? this.deviceId,
      deletedAt: deletedAt ?? this.deletedAt,
      notebookId: notebookId ?? this.notebookId,
      title: title ?? this.title,
      contentMd: contentMd ?? this.contentMd,
      contentHash: contentHash ?? this.contentHash,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (version.present) {
      map['version'] = Variable<int>(version.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (deviceId.present) {
      map['device_id'] = Variable<String>(deviceId.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<DateTime>(deletedAt.value);
    }
    if (notebookId.present) {
      map['notebook_id'] = Variable<String>(notebookId.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (contentMd.present) {
      map['content_md'] = Variable<String>(contentMd.value);
    }
    if (contentHash.present) {
      map['content_hash'] = Variable<String>(contentHash.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('NotesCompanion(')
          ..write('id: $id, ')
          ..write('version: $version, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deviceId: $deviceId, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('notebookId: $notebookId, ')
          ..write('title: $title, ')
          ..write('contentMd: $contentMd, ')
          ..write('contentHash: $contentHash, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $KnowledgePointsTable extends KnowledgePoints
    with TableInfo<$KnowledgePointsTable, KnowledgePointRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $KnowledgePointsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _versionMeta = const VerificationMeta(
    'version',
  );
  @override
  late final GeneratedColumn<int> version = GeneratedColumn<int>(
    'version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deviceIdMeta = const VerificationMeta(
    'deviceId',
  );
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
    'device_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<DateTime> deletedAt = GeneratedColumn<DateTime>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _notebookIdMeta = const VerificationMeta(
    'notebookId',
  );
  @override
  late final GeneratedColumn<String> notebookId = GeneratedColumn<String>(
    'notebook_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _definitionMeta = const VerificationMeta(
    'definition',
  );
  @override
  late final GeneratedColumn<String> definition = GeneratedColumn<String>(
    'definition',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _sourceNoteIdMeta = const VerificationMeta(
    'sourceNoteId',
  );
  @override
  late final GeneratedColumn<String> sourceNoteId = GeneratedColumn<String>(
    'source_note_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sourceStartMeta = const VerificationMeta(
    'sourceStart',
  );
  @override
  late final GeneratedColumn<int> sourceStart = GeneratedColumn<int>(
    'source_start',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sourceEndMeta = const VerificationMeta(
    'sourceEnd',
  );
  @override
  late final GeneratedColumn<int> sourceEnd = GeneratedColumn<int>(
    'source_end',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sourceQuoteMeta = const VerificationMeta(
    'sourceQuote',
  );
  @override
  late final GeneratedColumn<String> sourceQuote = GeneratedColumn<String>(
    'source_quote',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _originMeta = const VerificationMeta('origin');
  @override
  late final GeneratedColumn<String> origin = GeneratedColumn<String>(
    'origin',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('ai_extract'),
  );
  static const VerificationMeta _confidenceMeta = const VerificationMeta(
    'confidence',
  );
  @override
  late final GeneratedColumn<double> confidence = GeneratedColumn<double>(
    'confidence',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    defaultValue: const Constant(0.0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    version,
    updatedAt,
    deviceId,
    deletedAt,
    notebookId,
    name,
    type,
    definition,
    sourceNoteId,
    sourceStart,
    sourceEnd,
    sourceQuote,
    origin,
    confidence,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'knowledge_points';
  @override
  VerificationContext validateIntegrity(
    Insertable<KnowledgePointRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('version')) {
      context.handle(
        _versionMeta,
        version.isAcceptableOrUnknown(data['version']!, _versionMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('device_id')) {
      context.handle(
        _deviceIdMeta,
        deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_deviceIdMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    if (data.containsKey('notebook_id')) {
      context.handle(
        _notebookIdMeta,
        notebookId.isAcceptableOrUnknown(data['notebook_id']!, _notebookIdMeta),
      );
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    } else if (isInserting) {
      context.missing(_typeMeta);
    }
    if (data.containsKey('definition')) {
      context.handle(
        _definitionMeta,
        definition.isAcceptableOrUnknown(data['definition']!, _definitionMeta),
      );
    }
    if (data.containsKey('source_note_id')) {
      context.handle(
        _sourceNoteIdMeta,
        sourceNoteId.isAcceptableOrUnknown(
          data['source_note_id']!,
          _sourceNoteIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_sourceNoteIdMeta);
    }
    if (data.containsKey('source_start')) {
      context.handle(
        _sourceStartMeta,
        sourceStart.isAcceptableOrUnknown(
          data['source_start']!,
          _sourceStartMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_sourceStartMeta);
    }
    if (data.containsKey('source_end')) {
      context.handle(
        _sourceEndMeta,
        sourceEnd.isAcceptableOrUnknown(data['source_end']!, _sourceEndMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceEndMeta);
    }
    if (data.containsKey('source_quote')) {
      context.handle(
        _sourceQuoteMeta,
        sourceQuote.isAcceptableOrUnknown(
          data['source_quote']!,
          _sourceQuoteMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_sourceQuoteMeta);
    }
    if (data.containsKey('origin')) {
      context.handle(
        _originMeta,
        origin.isAcceptableOrUnknown(data['origin']!, _originMeta),
      );
    }
    if (data.containsKey('confidence')) {
      context.handle(
        _confidenceMeta,
        confidence.isAcceptableOrUnknown(data['confidence']!, _confidenceMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  KnowledgePointRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return KnowledgePointRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      version: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}version'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      deviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}device_id'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}deleted_at'],
      ),
      notebookId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}notebook_id'],
      ),
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}type'],
      )!,
      definition: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}definition'],
      )!,
      sourceNoteId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_note_id'],
      )!,
      sourceStart: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}source_start'],
      )!,
      sourceEnd: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}source_end'],
      )!,
      sourceQuote: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_quote'],
      )!,
      origin: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}origin'],
      )!,
      confidence: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}confidence'],
      )!,
    );
  }

  @override
  $KnowledgePointsTable createAlias(String alias) {
    return $KnowledgePointsTable(attachedDatabase, alias);
  }
}

class KnowledgePointRow extends DataClass
    implements Insertable<KnowledgePointRow> {
  /// ULID 主键。
  final String id;

  /// 本地递增版本号，服务端接管后用于 LWW 冲突判定。
  final int version;
  final DateTime updatedAt;

  /// 产生该次变更的设备，用于同步自回声过滤。
  final String deviceId;

  /// tombstone 软删除：非空即删除，删除靠它传播，不物理删（§11）。
  final DateTime? deletedAt;
  final String? notebookId;
  final String name;

  /// 枚举 concept/formula/theorem/method/fact/myth 的 name。
  final String type;
  final String definition;
  final String sourceNoteId;
  final int sourceStart;
  final int sourceEnd;
  final String sourceQuote;

  /// 来源：ai_extract / user_manual / tutor 等。
  final String origin;
  final double confidence;
  const KnowledgePointRow({
    required this.id,
    required this.version,
    required this.updatedAt,
    required this.deviceId,
    this.deletedAt,
    this.notebookId,
    required this.name,
    required this.type,
    required this.definition,
    required this.sourceNoteId,
    required this.sourceStart,
    required this.sourceEnd,
    required this.sourceQuote,
    required this.origin,
    required this.confidence,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['version'] = Variable<int>(version);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    map['device_id'] = Variable<String>(deviceId);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<DateTime>(deletedAt);
    }
    if (!nullToAbsent || notebookId != null) {
      map['notebook_id'] = Variable<String>(notebookId);
    }
    map['name'] = Variable<String>(name);
    map['type'] = Variable<String>(type);
    map['definition'] = Variable<String>(definition);
    map['source_note_id'] = Variable<String>(sourceNoteId);
    map['source_start'] = Variable<int>(sourceStart);
    map['source_end'] = Variable<int>(sourceEnd);
    map['source_quote'] = Variable<String>(sourceQuote);
    map['origin'] = Variable<String>(origin);
    map['confidence'] = Variable<double>(confidence);
    return map;
  }

  KnowledgePointsCompanion toCompanion(bool nullToAbsent) {
    return KnowledgePointsCompanion(
      id: Value(id),
      version: Value(version),
      updatedAt: Value(updatedAt),
      deviceId: Value(deviceId),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
      notebookId: notebookId == null && nullToAbsent
          ? const Value.absent()
          : Value(notebookId),
      name: Value(name),
      type: Value(type),
      definition: Value(definition),
      sourceNoteId: Value(sourceNoteId),
      sourceStart: Value(sourceStart),
      sourceEnd: Value(sourceEnd),
      sourceQuote: Value(sourceQuote),
      origin: Value(origin),
      confidence: Value(confidence),
    );
  }

  factory KnowledgePointRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return KnowledgePointRow(
      id: serializer.fromJson<String>(json['id']),
      version: serializer.fromJson<int>(json['version']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      deviceId: serializer.fromJson<String>(json['deviceId']),
      deletedAt: serializer.fromJson<DateTime?>(json['deletedAt']),
      notebookId: serializer.fromJson<String?>(json['notebookId']),
      name: serializer.fromJson<String>(json['name']),
      type: serializer.fromJson<String>(json['type']),
      definition: serializer.fromJson<String>(json['definition']),
      sourceNoteId: serializer.fromJson<String>(json['sourceNoteId']),
      sourceStart: serializer.fromJson<int>(json['sourceStart']),
      sourceEnd: serializer.fromJson<int>(json['sourceEnd']),
      sourceQuote: serializer.fromJson<String>(json['sourceQuote']),
      origin: serializer.fromJson<String>(json['origin']),
      confidence: serializer.fromJson<double>(json['confidence']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'version': serializer.toJson<int>(version),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'deviceId': serializer.toJson<String>(deviceId),
      'deletedAt': serializer.toJson<DateTime?>(deletedAt),
      'notebookId': serializer.toJson<String?>(notebookId),
      'name': serializer.toJson<String>(name),
      'type': serializer.toJson<String>(type),
      'definition': serializer.toJson<String>(definition),
      'sourceNoteId': serializer.toJson<String>(sourceNoteId),
      'sourceStart': serializer.toJson<int>(sourceStart),
      'sourceEnd': serializer.toJson<int>(sourceEnd),
      'sourceQuote': serializer.toJson<String>(sourceQuote),
      'origin': serializer.toJson<String>(origin),
      'confidence': serializer.toJson<double>(confidence),
    };
  }

  KnowledgePointRow copyWith({
    String? id,
    int? version,
    DateTime? updatedAt,
    String? deviceId,
    Value<DateTime?> deletedAt = const Value.absent(),
    Value<String?> notebookId = const Value.absent(),
    String? name,
    String? type,
    String? definition,
    String? sourceNoteId,
    int? sourceStart,
    int? sourceEnd,
    String? sourceQuote,
    String? origin,
    double? confidence,
  }) => KnowledgePointRow(
    id: id ?? this.id,
    version: version ?? this.version,
    updatedAt: updatedAt ?? this.updatedAt,
    deviceId: deviceId ?? this.deviceId,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
    notebookId: notebookId.present ? notebookId.value : this.notebookId,
    name: name ?? this.name,
    type: type ?? this.type,
    definition: definition ?? this.definition,
    sourceNoteId: sourceNoteId ?? this.sourceNoteId,
    sourceStart: sourceStart ?? this.sourceStart,
    sourceEnd: sourceEnd ?? this.sourceEnd,
    sourceQuote: sourceQuote ?? this.sourceQuote,
    origin: origin ?? this.origin,
    confidence: confidence ?? this.confidence,
  );
  KnowledgePointRow copyWithCompanion(KnowledgePointsCompanion data) {
    return KnowledgePointRow(
      id: data.id.present ? data.id.value : this.id,
      version: data.version.present ? data.version.value : this.version,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      notebookId: data.notebookId.present
          ? data.notebookId.value
          : this.notebookId,
      name: data.name.present ? data.name.value : this.name,
      type: data.type.present ? data.type.value : this.type,
      definition: data.definition.present
          ? data.definition.value
          : this.definition,
      sourceNoteId: data.sourceNoteId.present
          ? data.sourceNoteId.value
          : this.sourceNoteId,
      sourceStart: data.sourceStart.present
          ? data.sourceStart.value
          : this.sourceStart,
      sourceEnd: data.sourceEnd.present ? data.sourceEnd.value : this.sourceEnd,
      sourceQuote: data.sourceQuote.present
          ? data.sourceQuote.value
          : this.sourceQuote,
      origin: data.origin.present ? data.origin.value : this.origin,
      confidence: data.confidence.present
          ? data.confidence.value
          : this.confidence,
    );
  }

  @override
  String toString() {
    return (StringBuffer('KnowledgePointRow(')
          ..write('id: $id, ')
          ..write('version: $version, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deviceId: $deviceId, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('notebookId: $notebookId, ')
          ..write('name: $name, ')
          ..write('type: $type, ')
          ..write('definition: $definition, ')
          ..write('sourceNoteId: $sourceNoteId, ')
          ..write('sourceStart: $sourceStart, ')
          ..write('sourceEnd: $sourceEnd, ')
          ..write('sourceQuote: $sourceQuote, ')
          ..write('origin: $origin, ')
          ..write('confidence: $confidence')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    version,
    updatedAt,
    deviceId,
    deletedAt,
    notebookId,
    name,
    type,
    definition,
    sourceNoteId,
    sourceStart,
    sourceEnd,
    sourceQuote,
    origin,
    confidence,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is KnowledgePointRow &&
          other.id == this.id &&
          other.version == this.version &&
          other.updatedAt == this.updatedAt &&
          other.deviceId == this.deviceId &&
          other.deletedAt == this.deletedAt &&
          other.notebookId == this.notebookId &&
          other.name == this.name &&
          other.type == this.type &&
          other.definition == this.definition &&
          other.sourceNoteId == this.sourceNoteId &&
          other.sourceStart == this.sourceStart &&
          other.sourceEnd == this.sourceEnd &&
          other.sourceQuote == this.sourceQuote &&
          other.origin == this.origin &&
          other.confidence == this.confidence);
}

class KnowledgePointsCompanion extends UpdateCompanion<KnowledgePointRow> {
  final Value<String> id;
  final Value<int> version;
  final Value<DateTime> updatedAt;
  final Value<String> deviceId;
  final Value<DateTime?> deletedAt;
  final Value<String?> notebookId;
  final Value<String> name;
  final Value<String> type;
  final Value<String> definition;
  final Value<String> sourceNoteId;
  final Value<int> sourceStart;
  final Value<int> sourceEnd;
  final Value<String> sourceQuote;
  final Value<String> origin;
  final Value<double> confidence;
  final Value<int> rowid;
  const KnowledgePointsCompanion({
    this.id = const Value.absent(),
    this.version = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.notebookId = const Value.absent(),
    this.name = const Value.absent(),
    this.type = const Value.absent(),
    this.definition = const Value.absent(),
    this.sourceNoteId = const Value.absent(),
    this.sourceStart = const Value.absent(),
    this.sourceEnd = const Value.absent(),
    this.sourceQuote = const Value.absent(),
    this.origin = const Value.absent(),
    this.confidence = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  KnowledgePointsCompanion.insert({
    required String id,
    this.version = const Value.absent(),
    required DateTime updatedAt,
    required String deviceId,
    this.deletedAt = const Value.absent(),
    this.notebookId = const Value.absent(),
    required String name,
    required String type,
    this.definition = const Value.absent(),
    required String sourceNoteId,
    required int sourceStart,
    required int sourceEnd,
    required String sourceQuote,
    this.origin = const Value.absent(),
    this.confidence = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       updatedAt = Value(updatedAt),
       deviceId = Value(deviceId),
       name = Value(name),
       type = Value(type),
       sourceNoteId = Value(sourceNoteId),
       sourceStart = Value(sourceStart),
       sourceEnd = Value(sourceEnd),
       sourceQuote = Value(sourceQuote);
  static Insertable<KnowledgePointRow> custom({
    Expression<String>? id,
    Expression<int>? version,
    Expression<DateTime>? updatedAt,
    Expression<String>? deviceId,
    Expression<DateTime>? deletedAt,
    Expression<String>? notebookId,
    Expression<String>? name,
    Expression<String>? type,
    Expression<String>? definition,
    Expression<String>? sourceNoteId,
    Expression<int>? sourceStart,
    Expression<int>? sourceEnd,
    Expression<String>? sourceQuote,
    Expression<String>? origin,
    Expression<double>? confidence,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (version != null) 'version': version,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deviceId != null) 'device_id': deviceId,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (notebookId != null) 'notebook_id': notebookId,
      if (name != null) 'name': name,
      if (type != null) 'type': type,
      if (definition != null) 'definition': definition,
      if (sourceNoteId != null) 'source_note_id': sourceNoteId,
      if (sourceStart != null) 'source_start': sourceStart,
      if (sourceEnd != null) 'source_end': sourceEnd,
      if (sourceQuote != null) 'source_quote': sourceQuote,
      if (origin != null) 'origin': origin,
      if (confidence != null) 'confidence': confidence,
      if (rowid != null) 'rowid': rowid,
    });
  }

  KnowledgePointsCompanion copyWith({
    Value<String>? id,
    Value<int>? version,
    Value<DateTime>? updatedAt,
    Value<String>? deviceId,
    Value<DateTime?>? deletedAt,
    Value<String?>? notebookId,
    Value<String>? name,
    Value<String>? type,
    Value<String>? definition,
    Value<String>? sourceNoteId,
    Value<int>? sourceStart,
    Value<int>? sourceEnd,
    Value<String>? sourceQuote,
    Value<String>? origin,
    Value<double>? confidence,
    Value<int>? rowid,
  }) {
    return KnowledgePointsCompanion(
      id: id ?? this.id,
      version: version ?? this.version,
      updatedAt: updatedAt ?? this.updatedAt,
      deviceId: deviceId ?? this.deviceId,
      deletedAt: deletedAt ?? this.deletedAt,
      notebookId: notebookId ?? this.notebookId,
      name: name ?? this.name,
      type: type ?? this.type,
      definition: definition ?? this.definition,
      sourceNoteId: sourceNoteId ?? this.sourceNoteId,
      sourceStart: sourceStart ?? this.sourceStart,
      sourceEnd: sourceEnd ?? this.sourceEnd,
      sourceQuote: sourceQuote ?? this.sourceQuote,
      origin: origin ?? this.origin,
      confidence: confidence ?? this.confidence,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (version.present) {
      map['version'] = Variable<int>(version.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (deviceId.present) {
      map['device_id'] = Variable<String>(deviceId.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<DateTime>(deletedAt.value);
    }
    if (notebookId.present) {
      map['notebook_id'] = Variable<String>(notebookId.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (definition.present) {
      map['definition'] = Variable<String>(definition.value);
    }
    if (sourceNoteId.present) {
      map['source_note_id'] = Variable<String>(sourceNoteId.value);
    }
    if (sourceStart.present) {
      map['source_start'] = Variable<int>(sourceStart.value);
    }
    if (sourceEnd.present) {
      map['source_end'] = Variable<int>(sourceEnd.value);
    }
    if (sourceQuote.present) {
      map['source_quote'] = Variable<String>(sourceQuote.value);
    }
    if (origin.present) {
      map['origin'] = Variable<String>(origin.value);
    }
    if (confidence.present) {
      map['confidence'] = Variable<double>(confidence.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('KnowledgePointsCompanion(')
          ..write('id: $id, ')
          ..write('version: $version, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deviceId: $deviceId, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('notebookId: $notebookId, ')
          ..write('name: $name, ')
          ..write('type: $type, ')
          ..write('definition: $definition, ')
          ..write('sourceNoteId: $sourceNoteId, ')
          ..write('sourceStart: $sourceStart, ')
          ..write('sourceEnd: $sourceEnd, ')
          ..write('sourceQuote: $sourceQuote, ')
          ..write('origin: $origin, ')
          ..write('confidence: $confidence, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PrerequisiteEdgesTable extends PrerequisiteEdges
    with TableInfo<$PrerequisiteEdgesTable, PrerequisiteEdgeRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PrerequisiteEdgesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _versionMeta = const VerificationMeta(
    'version',
  );
  @override
  late final GeneratedColumn<int> version = GeneratedColumn<int>(
    'version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deviceIdMeta = const VerificationMeta(
    'deviceId',
  );
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
    'device_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<DateTime> deletedAt = GeneratedColumn<DateTime>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _fromKpIdMeta = const VerificationMeta(
    'fromKpId',
  );
  @override
  late final GeneratedColumn<String> fromKpId = GeneratedColumn<String>(
    'from_kp_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _toKpIdMeta = const VerificationMeta('toKpId');
  @override
  late final GeneratedColumn<String> toKpId = GeneratedColumn<String>(
    'to_kp_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _reasonMeta = const VerificationMeta('reason');
  @override
  late final GeneratedColumn<String> reason = GeneratedColumn<String>(
    'reason',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _originMeta = const VerificationMeta('origin');
  @override
  late final GeneratedColumn<String> origin = GeneratedColumn<String>(
    'origin',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('ai'),
  );
  static const VerificationMeta _confidenceMeta = const VerificationMeta(
    'confidence',
  );
  @override
  late final GeneratedColumn<double> confidence = GeneratedColumn<double>(
    'confidence',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    defaultValue: const Constant(0.0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    version,
    updatedAt,
    deviceId,
    deletedAt,
    fromKpId,
    toKpId,
    reason,
    origin,
    confidence,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'prerequisite_edges';
  @override
  VerificationContext validateIntegrity(
    Insertable<PrerequisiteEdgeRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('version')) {
      context.handle(
        _versionMeta,
        version.isAcceptableOrUnknown(data['version']!, _versionMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('device_id')) {
      context.handle(
        _deviceIdMeta,
        deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_deviceIdMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    if (data.containsKey('from_kp_id')) {
      context.handle(
        _fromKpIdMeta,
        fromKpId.isAcceptableOrUnknown(data['from_kp_id']!, _fromKpIdMeta),
      );
    } else if (isInserting) {
      context.missing(_fromKpIdMeta);
    }
    if (data.containsKey('to_kp_id')) {
      context.handle(
        _toKpIdMeta,
        toKpId.isAcceptableOrUnknown(data['to_kp_id']!, _toKpIdMeta),
      );
    } else if (isInserting) {
      context.missing(_toKpIdMeta);
    }
    if (data.containsKey('reason')) {
      context.handle(
        _reasonMeta,
        reason.isAcceptableOrUnknown(data['reason']!, _reasonMeta),
      );
    }
    if (data.containsKey('origin')) {
      context.handle(
        _originMeta,
        origin.isAcceptableOrUnknown(data['origin']!, _originMeta),
      );
    }
    if (data.containsKey('confidence')) {
      context.handle(
        _confidenceMeta,
        confidence.isAcceptableOrUnknown(data['confidence']!, _confidenceMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PrerequisiteEdgeRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PrerequisiteEdgeRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      version: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}version'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      deviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}device_id'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}deleted_at'],
      ),
      fromKpId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}from_kp_id'],
      )!,
      toKpId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}to_kp_id'],
      )!,
      reason: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reason'],
      )!,
      origin: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}origin'],
      )!,
      confidence: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}confidence'],
      )!,
    );
  }

  @override
  $PrerequisiteEdgesTable createAlias(String alias) {
    return $PrerequisiteEdgesTable(attachedDatabase, alias);
  }
}

class PrerequisiteEdgeRow extends DataClass
    implements Insertable<PrerequisiteEdgeRow> {
  /// ULID 主键。
  final String id;

  /// 本地递增版本号，服务端接管后用于 LWW 冲突判定。
  final int version;
  final DateTime updatedAt;

  /// 产生该次变更的设备，用于同步自回声过滤。
  final String deviceId;

  /// tombstone 软删除：非空即删除，删除靠它传播，不物理删（§11）。
  final DateTime? deletedAt;

  /// 前置知识点（先学的）。
  final String fromKpId;

  /// 后继知识点（依赖 from 的）。
  final String toKpId;
  final String reason;
  final String origin;
  final double confidence;
  const PrerequisiteEdgeRow({
    required this.id,
    required this.version,
    required this.updatedAt,
    required this.deviceId,
    this.deletedAt,
    required this.fromKpId,
    required this.toKpId,
    required this.reason,
    required this.origin,
    required this.confidence,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['version'] = Variable<int>(version);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    map['device_id'] = Variable<String>(deviceId);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<DateTime>(deletedAt);
    }
    map['from_kp_id'] = Variable<String>(fromKpId);
    map['to_kp_id'] = Variable<String>(toKpId);
    map['reason'] = Variable<String>(reason);
    map['origin'] = Variable<String>(origin);
    map['confidence'] = Variable<double>(confidence);
    return map;
  }

  PrerequisiteEdgesCompanion toCompanion(bool nullToAbsent) {
    return PrerequisiteEdgesCompanion(
      id: Value(id),
      version: Value(version),
      updatedAt: Value(updatedAt),
      deviceId: Value(deviceId),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
      fromKpId: Value(fromKpId),
      toKpId: Value(toKpId),
      reason: Value(reason),
      origin: Value(origin),
      confidence: Value(confidence),
    );
  }

  factory PrerequisiteEdgeRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PrerequisiteEdgeRow(
      id: serializer.fromJson<String>(json['id']),
      version: serializer.fromJson<int>(json['version']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      deviceId: serializer.fromJson<String>(json['deviceId']),
      deletedAt: serializer.fromJson<DateTime?>(json['deletedAt']),
      fromKpId: serializer.fromJson<String>(json['fromKpId']),
      toKpId: serializer.fromJson<String>(json['toKpId']),
      reason: serializer.fromJson<String>(json['reason']),
      origin: serializer.fromJson<String>(json['origin']),
      confidence: serializer.fromJson<double>(json['confidence']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'version': serializer.toJson<int>(version),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'deviceId': serializer.toJson<String>(deviceId),
      'deletedAt': serializer.toJson<DateTime?>(deletedAt),
      'fromKpId': serializer.toJson<String>(fromKpId),
      'toKpId': serializer.toJson<String>(toKpId),
      'reason': serializer.toJson<String>(reason),
      'origin': serializer.toJson<String>(origin),
      'confidence': serializer.toJson<double>(confidence),
    };
  }

  PrerequisiteEdgeRow copyWith({
    String? id,
    int? version,
    DateTime? updatedAt,
    String? deviceId,
    Value<DateTime?> deletedAt = const Value.absent(),
    String? fromKpId,
    String? toKpId,
    String? reason,
    String? origin,
    double? confidence,
  }) => PrerequisiteEdgeRow(
    id: id ?? this.id,
    version: version ?? this.version,
    updatedAt: updatedAt ?? this.updatedAt,
    deviceId: deviceId ?? this.deviceId,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
    fromKpId: fromKpId ?? this.fromKpId,
    toKpId: toKpId ?? this.toKpId,
    reason: reason ?? this.reason,
    origin: origin ?? this.origin,
    confidence: confidence ?? this.confidence,
  );
  PrerequisiteEdgeRow copyWithCompanion(PrerequisiteEdgesCompanion data) {
    return PrerequisiteEdgeRow(
      id: data.id.present ? data.id.value : this.id,
      version: data.version.present ? data.version.value : this.version,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      fromKpId: data.fromKpId.present ? data.fromKpId.value : this.fromKpId,
      toKpId: data.toKpId.present ? data.toKpId.value : this.toKpId,
      reason: data.reason.present ? data.reason.value : this.reason,
      origin: data.origin.present ? data.origin.value : this.origin,
      confidence: data.confidence.present
          ? data.confidence.value
          : this.confidence,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PrerequisiteEdgeRow(')
          ..write('id: $id, ')
          ..write('version: $version, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deviceId: $deviceId, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('fromKpId: $fromKpId, ')
          ..write('toKpId: $toKpId, ')
          ..write('reason: $reason, ')
          ..write('origin: $origin, ')
          ..write('confidence: $confidence')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    version,
    updatedAt,
    deviceId,
    deletedAt,
    fromKpId,
    toKpId,
    reason,
    origin,
    confidence,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PrerequisiteEdgeRow &&
          other.id == this.id &&
          other.version == this.version &&
          other.updatedAt == this.updatedAt &&
          other.deviceId == this.deviceId &&
          other.deletedAt == this.deletedAt &&
          other.fromKpId == this.fromKpId &&
          other.toKpId == this.toKpId &&
          other.reason == this.reason &&
          other.origin == this.origin &&
          other.confidence == this.confidence);
}

class PrerequisiteEdgesCompanion extends UpdateCompanion<PrerequisiteEdgeRow> {
  final Value<String> id;
  final Value<int> version;
  final Value<DateTime> updatedAt;
  final Value<String> deviceId;
  final Value<DateTime?> deletedAt;
  final Value<String> fromKpId;
  final Value<String> toKpId;
  final Value<String> reason;
  final Value<String> origin;
  final Value<double> confidence;
  final Value<int> rowid;
  const PrerequisiteEdgesCompanion({
    this.id = const Value.absent(),
    this.version = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.fromKpId = const Value.absent(),
    this.toKpId = const Value.absent(),
    this.reason = const Value.absent(),
    this.origin = const Value.absent(),
    this.confidence = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PrerequisiteEdgesCompanion.insert({
    required String id,
    this.version = const Value.absent(),
    required DateTime updatedAt,
    required String deviceId,
    this.deletedAt = const Value.absent(),
    required String fromKpId,
    required String toKpId,
    this.reason = const Value.absent(),
    this.origin = const Value.absent(),
    this.confidence = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       updatedAt = Value(updatedAt),
       deviceId = Value(deviceId),
       fromKpId = Value(fromKpId),
       toKpId = Value(toKpId);
  static Insertable<PrerequisiteEdgeRow> custom({
    Expression<String>? id,
    Expression<int>? version,
    Expression<DateTime>? updatedAt,
    Expression<String>? deviceId,
    Expression<DateTime>? deletedAt,
    Expression<String>? fromKpId,
    Expression<String>? toKpId,
    Expression<String>? reason,
    Expression<String>? origin,
    Expression<double>? confidence,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (version != null) 'version': version,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deviceId != null) 'device_id': deviceId,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (fromKpId != null) 'from_kp_id': fromKpId,
      if (toKpId != null) 'to_kp_id': toKpId,
      if (reason != null) 'reason': reason,
      if (origin != null) 'origin': origin,
      if (confidence != null) 'confidence': confidence,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PrerequisiteEdgesCompanion copyWith({
    Value<String>? id,
    Value<int>? version,
    Value<DateTime>? updatedAt,
    Value<String>? deviceId,
    Value<DateTime?>? deletedAt,
    Value<String>? fromKpId,
    Value<String>? toKpId,
    Value<String>? reason,
    Value<String>? origin,
    Value<double>? confidence,
    Value<int>? rowid,
  }) {
    return PrerequisiteEdgesCompanion(
      id: id ?? this.id,
      version: version ?? this.version,
      updatedAt: updatedAt ?? this.updatedAt,
      deviceId: deviceId ?? this.deviceId,
      deletedAt: deletedAt ?? this.deletedAt,
      fromKpId: fromKpId ?? this.fromKpId,
      toKpId: toKpId ?? this.toKpId,
      reason: reason ?? this.reason,
      origin: origin ?? this.origin,
      confidence: confidence ?? this.confidence,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (version.present) {
      map['version'] = Variable<int>(version.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (deviceId.present) {
      map['device_id'] = Variable<String>(deviceId.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<DateTime>(deletedAt.value);
    }
    if (fromKpId.present) {
      map['from_kp_id'] = Variable<String>(fromKpId.value);
    }
    if (toKpId.present) {
      map['to_kp_id'] = Variable<String>(toKpId.value);
    }
    if (reason.present) {
      map['reason'] = Variable<String>(reason.value);
    }
    if (origin.present) {
      map['origin'] = Variable<String>(origin.value);
    }
    if (confidence.present) {
      map['confidence'] = Variable<double>(confidence.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PrerequisiteEdgesCompanion(')
          ..write('id: $id, ')
          ..write('version: $version, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deviceId: $deviceId, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('fromKpId: $fromKpId, ')
          ..write('toKpId: $toKpId, ')
          ..write('reason: $reason, ')
          ..write('origin: $origin, ')
          ..write('confidence: $confidence, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MasteryRecordsTable extends MasteryRecords
    with TableInfo<$MasteryRecordsTable, MasteryRecordRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MasteryRecordsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _versionMeta = const VerificationMeta(
    'version',
  );
  @override
  late final GeneratedColumn<int> version = GeneratedColumn<int>(
    'version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deviceIdMeta = const VerificationMeta(
    'deviceId',
  );
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
    'device_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<DateTime> deletedAt = GeneratedColumn<DateTime>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _kpIdMeta = const VerificationMeta('kpId');
  @override
  late final GeneratedColumn<String> kpId = GeneratedColumn<String>(
    'kp_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  @override
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('self'),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    version,
    updatedAt,
    deviceId,
    deletedAt,
    kpId,
    status,
    source,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'mastery_records';
  @override
  VerificationContext validateIntegrity(
    Insertable<MasteryRecordRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('version')) {
      context.handle(
        _versionMeta,
        version.isAcceptableOrUnknown(data['version']!, _versionMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('device_id')) {
      context.handle(
        _deviceIdMeta,
        deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_deviceIdMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    if (data.containsKey('kp_id')) {
      context.handle(
        _kpIdMeta,
        kpId.isAcceptableOrUnknown(data['kp_id']!, _kpIdMeta),
      );
    } else if (isInserting) {
      context.missing(_kpIdMeta);
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  MasteryRecordRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MasteryRecordRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      version: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}version'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      deviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}device_id'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}deleted_at'],
      ),
      kpId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kp_id'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      )!,
    );
  }

  @override
  $MasteryRecordsTable createAlias(String alias) {
    return $MasteryRecordsTable(attachedDatabase, alias);
  }
}

class MasteryRecordRow extends DataClass
    implements Insertable<MasteryRecordRow> {
  /// ULID 主键。
  final String id;

  /// 本地递增版本号，服务端接管后用于 LWW 冲突判定。
  final int version;
  final DateTime updatedAt;

  /// 产生该次变更的设备，用于同步自回声过滤。
  final String deviceId;

  /// tombstone 软删除：非空即删除，删除靠它传播，不物理删（§11）。
  final DateTime? deletedAt;
  final String kpId;

  /// unknown/not_mastered/learning/mastered/abandoned。
  final String status;

  /// self/ai/tutor_cascade（级联降级产生）。
  final String source;
  const MasteryRecordRow({
    required this.id,
    required this.version,
    required this.updatedAt,
    required this.deviceId,
    this.deletedAt,
    required this.kpId,
    required this.status,
    required this.source,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['version'] = Variable<int>(version);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    map['device_id'] = Variable<String>(deviceId);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<DateTime>(deletedAt);
    }
    map['kp_id'] = Variable<String>(kpId);
    map['status'] = Variable<String>(status);
    map['source'] = Variable<String>(source);
    return map;
  }

  MasteryRecordsCompanion toCompanion(bool nullToAbsent) {
    return MasteryRecordsCompanion(
      id: Value(id),
      version: Value(version),
      updatedAt: Value(updatedAt),
      deviceId: Value(deviceId),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
      kpId: Value(kpId),
      status: Value(status),
      source: Value(source),
    );
  }

  factory MasteryRecordRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MasteryRecordRow(
      id: serializer.fromJson<String>(json['id']),
      version: serializer.fromJson<int>(json['version']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      deviceId: serializer.fromJson<String>(json['deviceId']),
      deletedAt: serializer.fromJson<DateTime?>(json['deletedAt']),
      kpId: serializer.fromJson<String>(json['kpId']),
      status: serializer.fromJson<String>(json['status']),
      source: serializer.fromJson<String>(json['source']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'version': serializer.toJson<int>(version),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'deviceId': serializer.toJson<String>(deviceId),
      'deletedAt': serializer.toJson<DateTime?>(deletedAt),
      'kpId': serializer.toJson<String>(kpId),
      'status': serializer.toJson<String>(status),
      'source': serializer.toJson<String>(source),
    };
  }

  MasteryRecordRow copyWith({
    String? id,
    int? version,
    DateTime? updatedAt,
    String? deviceId,
    Value<DateTime?> deletedAt = const Value.absent(),
    String? kpId,
    String? status,
    String? source,
  }) => MasteryRecordRow(
    id: id ?? this.id,
    version: version ?? this.version,
    updatedAt: updatedAt ?? this.updatedAt,
    deviceId: deviceId ?? this.deviceId,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
    kpId: kpId ?? this.kpId,
    status: status ?? this.status,
    source: source ?? this.source,
  );
  MasteryRecordRow copyWithCompanion(MasteryRecordsCompanion data) {
    return MasteryRecordRow(
      id: data.id.present ? data.id.value : this.id,
      version: data.version.present ? data.version.value : this.version,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      kpId: data.kpId.present ? data.kpId.value : this.kpId,
      status: data.status.present ? data.status.value : this.status,
      source: data.source.present ? data.source.value : this.source,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MasteryRecordRow(')
          ..write('id: $id, ')
          ..write('version: $version, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deviceId: $deviceId, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('kpId: $kpId, ')
          ..write('status: $status, ')
          ..write('source: $source')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    version,
    updatedAt,
    deviceId,
    deletedAt,
    kpId,
    status,
    source,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MasteryRecordRow &&
          other.id == this.id &&
          other.version == this.version &&
          other.updatedAt == this.updatedAt &&
          other.deviceId == this.deviceId &&
          other.deletedAt == this.deletedAt &&
          other.kpId == this.kpId &&
          other.status == this.status &&
          other.source == this.source);
}

class MasteryRecordsCompanion extends UpdateCompanion<MasteryRecordRow> {
  final Value<String> id;
  final Value<int> version;
  final Value<DateTime> updatedAt;
  final Value<String> deviceId;
  final Value<DateTime?> deletedAt;
  final Value<String> kpId;
  final Value<String> status;
  final Value<String> source;
  final Value<int> rowid;
  const MasteryRecordsCompanion({
    this.id = const Value.absent(),
    this.version = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.kpId = const Value.absent(),
    this.status = const Value.absent(),
    this.source = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MasteryRecordsCompanion.insert({
    required String id,
    this.version = const Value.absent(),
    required DateTime updatedAt,
    required String deviceId,
    this.deletedAt = const Value.absent(),
    required String kpId,
    required String status,
    this.source = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       updatedAt = Value(updatedAt),
       deviceId = Value(deviceId),
       kpId = Value(kpId),
       status = Value(status);
  static Insertable<MasteryRecordRow> custom({
    Expression<String>? id,
    Expression<int>? version,
    Expression<DateTime>? updatedAt,
    Expression<String>? deviceId,
    Expression<DateTime>? deletedAt,
    Expression<String>? kpId,
    Expression<String>? status,
    Expression<String>? source,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (version != null) 'version': version,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deviceId != null) 'device_id': deviceId,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (kpId != null) 'kp_id': kpId,
      if (status != null) 'status': status,
      if (source != null) 'source': source,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MasteryRecordsCompanion copyWith({
    Value<String>? id,
    Value<int>? version,
    Value<DateTime>? updatedAt,
    Value<String>? deviceId,
    Value<DateTime?>? deletedAt,
    Value<String>? kpId,
    Value<String>? status,
    Value<String>? source,
    Value<int>? rowid,
  }) {
    return MasteryRecordsCompanion(
      id: id ?? this.id,
      version: version ?? this.version,
      updatedAt: updatedAt ?? this.updatedAt,
      deviceId: deviceId ?? this.deviceId,
      deletedAt: deletedAt ?? this.deletedAt,
      kpId: kpId ?? this.kpId,
      status: status ?? this.status,
      source: source ?? this.source,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (version.present) {
      map['version'] = Variable<int>(version.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (deviceId.present) {
      map['device_id'] = Variable<String>(deviceId.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<DateTime>(deletedAt.value);
    }
    if (kpId.present) {
      map['kp_id'] = Variable<String>(kpId.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MasteryRecordsCompanion(')
          ..write('id: $id, ')
          ..write('version: $version, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deviceId: $deviceId, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('kpId: $kpId, ')
          ..write('status: $status, ')
          ..write('source: $source, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CardsTable extends Cards with TableInfo<$CardsTable, CardRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CardsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _versionMeta = const VerificationMeta(
    'version',
  );
  @override
  late final GeneratedColumn<int> version = GeneratedColumn<int>(
    'version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deviceIdMeta = const VerificationMeta(
    'deviceId',
  );
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
    'device_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<DateTime> deletedAt = GeneratedColumn<DateTime>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sourceRefMeta = const VerificationMeta(
    'sourceRef',
  );
  @override
  late final GeneratedColumn<String> sourceRef = GeneratedColumn<String>(
    'source_ref',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('{}'),
  );
  static const VerificationMeta _parentCardIdMeta = const VerificationMeta(
    'parentCardId',
  );
  @override
  late final GeneratedColumn<String> parentCardId = GeneratedColumn<String>(
    'parent_card_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _regeneratedFromIdMeta = const VerificationMeta(
    'regeneratedFromId',
  );
  @override
  late final GeneratedColumn<String> regeneratedFromId =
      GeneratedColumn<String>(
        'regenerated_from_id',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _contentMdMeta = const VerificationMeta(
    'contentMd',
  );
  @override
  late final GeneratedColumn<String> contentMd = GeneratedColumn<String>(
    'content_md',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _sessionIdMeta = const VerificationMeta(
    'sessionId',
  );
  @override
  late final GeneratedColumn<String> sessionId = GeneratedColumn<String>(
    'session_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _modelIdMeta = const VerificationMeta(
    'modelId',
  );
  @override
  late final GeneratedColumn<String> modelId = GeneratedColumn<String>(
    'model_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    version,
    updatedAt,
    deviceId,
    deletedAt,
    type,
    sourceRef,
    parentCardId,
    regeneratedFromId,
    contentMd,
    sessionId,
    modelId,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'cards';
  @override
  VerificationContext validateIntegrity(
    Insertable<CardRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('version')) {
      context.handle(
        _versionMeta,
        version.isAcceptableOrUnknown(data['version']!, _versionMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('device_id')) {
      context.handle(
        _deviceIdMeta,
        deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_deviceIdMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    } else if (isInserting) {
      context.missing(_typeMeta);
    }
    if (data.containsKey('source_ref')) {
      context.handle(
        _sourceRefMeta,
        sourceRef.isAcceptableOrUnknown(data['source_ref']!, _sourceRefMeta),
      );
    }
    if (data.containsKey('parent_card_id')) {
      context.handle(
        _parentCardIdMeta,
        parentCardId.isAcceptableOrUnknown(
          data['parent_card_id']!,
          _parentCardIdMeta,
        ),
      );
    }
    if (data.containsKey('regenerated_from_id')) {
      context.handle(
        _regeneratedFromIdMeta,
        regeneratedFromId.isAcceptableOrUnknown(
          data['regenerated_from_id']!,
          _regeneratedFromIdMeta,
        ),
      );
    }
    if (data.containsKey('content_md')) {
      context.handle(
        _contentMdMeta,
        contentMd.isAcceptableOrUnknown(data['content_md']!, _contentMdMeta),
      );
    }
    if (data.containsKey('session_id')) {
      context.handle(
        _sessionIdMeta,
        sessionId.isAcceptableOrUnknown(data['session_id']!, _sessionIdMeta),
      );
    }
    if (data.containsKey('model_id')) {
      context.handle(
        _modelIdMeta,
        modelId.isAcceptableOrUnknown(data['model_id']!, _modelIdMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  CardRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CardRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      version: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}version'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      deviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}device_id'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}deleted_at'],
      ),
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}type'],
      )!,
      sourceRef: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_ref'],
      )!,
      parentCardId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}parent_card_id'],
      ),
      regeneratedFromId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}regenerated_from_id'],
      ),
      contentMd: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content_md'],
      )!,
      sessionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}session_id'],
      ),
      modelId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}model_id'],
      ),
    );
  }

  @override
  $CardsTable createAlias(String alias) {
    return $CardsTable(attachedDatabase, alias);
  }
}

class CardRow extends DataClass implements Insertable<CardRow> {
  /// ULID 主键。
  final String id;

  /// 本地递增版本号，服务端接管后用于 LWW 冲突判定。
  final int version;
  final DateTime updatedAt;

  /// 产生该次变更的设备，用于同步自回声过滤。
  final String deviceId;

  /// tombstone 软删除：非空即删除，删除靠它传播，不物理删（§11）。
  final DateTime? deletedAt;

  /// qna/explanation/exercise/tutor_note/summary。
  final String type;

  /// 引用来源：{type, id} 的 JSON（source_ref）。
  final String sourceRef;
  final String? parentCardId;
  final String? regeneratedFromId;
  final String contentMd;
  final String? sessionId;
  final String? modelId;
  const CardRow({
    required this.id,
    required this.version,
    required this.updatedAt,
    required this.deviceId,
    this.deletedAt,
    required this.type,
    required this.sourceRef,
    this.parentCardId,
    this.regeneratedFromId,
    required this.contentMd,
    this.sessionId,
    this.modelId,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['version'] = Variable<int>(version);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    map['device_id'] = Variable<String>(deviceId);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<DateTime>(deletedAt);
    }
    map['type'] = Variable<String>(type);
    map['source_ref'] = Variable<String>(sourceRef);
    if (!nullToAbsent || parentCardId != null) {
      map['parent_card_id'] = Variable<String>(parentCardId);
    }
    if (!nullToAbsent || regeneratedFromId != null) {
      map['regenerated_from_id'] = Variable<String>(regeneratedFromId);
    }
    map['content_md'] = Variable<String>(contentMd);
    if (!nullToAbsent || sessionId != null) {
      map['session_id'] = Variable<String>(sessionId);
    }
    if (!nullToAbsent || modelId != null) {
      map['model_id'] = Variable<String>(modelId);
    }
    return map;
  }

  CardsCompanion toCompanion(bool nullToAbsent) {
    return CardsCompanion(
      id: Value(id),
      version: Value(version),
      updatedAt: Value(updatedAt),
      deviceId: Value(deviceId),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
      type: Value(type),
      sourceRef: Value(sourceRef),
      parentCardId: parentCardId == null && nullToAbsent
          ? const Value.absent()
          : Value(parentCardId),
      regeneratedFromId: regeneratedFromId == null && nullToAbsent
          ? const Value.absent()
          : Value(regeneratedFromId),
      contentMd: Value(contentMd),
      sessionId: sessionId == null && nullToAbsent
          ? const Value.absent()
          : Value(sessionId),
      modelId: modelId == null && nullToAbsent
          ? const Value.absent()
          : Value(modelId),
    );
  }

  factory CardRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CardRow(
      id: serializer.fromJson<String>(json['id']),
      version: serializer.fromJson<int>(json['version']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      deviceId: serializer.fromJson<String>(json['deviceId']),
      deletedAt: serializer.fromJson<DateTime?>(json['deletedAt']),
      type: serializer.fromJson<String>(json['type']),
      sourceRef: serializer.fromJson<String>(json['sourceRef']),
      parentCardId: serializer.fromJson<String?>(json['parentCardId']),
      regeneratedFromId: serializer.fromJson<String?>(
        json['regeneratedFromId'],
      ),
      contentMd: serializer.fromJson<String>(json['contentMd']),
      sessionId: serializer.fromJson<String?>(json['sessionId']),
      modelId: serializer.fromJson<String?>(json['modelId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'version': serializer.toJson<int>(version),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'deviceId': serializer.toJson<String>(deviceId),
      'deletedAt': serializer.toJson<DateTime?>(deletedAt),
      'type': serializer.toJson<String>(type),
      'sourceRef': serializer.toJson<String>(sourceRef),
      'parentCardId': serializer.toJson<String?>(parentCardId),
      'regeneratedFromId': serializer.toJson<String?>(regeneratedFromId),
      'contentMd': serializer.toJson<String>(contentMd),
      'sessionId': serializer.toJson<String?>(sessionId),
      'modelId': serializer.toJson<String?>(modelId),
    };
  }

  CardRow copyWith({
    String? id,
    int? version,
    DateTime? updatedAt,
    String? deviceId,
    Value<DateTime?> deletedAt = const Value.absent(),
    String? type,
    String? sourceRef,
    Value<String?> parentCardId = const Value.absent(),
    Value<String?> regeneratedFromId = const Value.absent(),
    String? contentMd,
    Value<String?> sessionId = const Value.absent(),
    Value<String?> modelId = const Value.absent(),
  }) => CardRow(
    id: id ?? this.id,
    version: version ?? this.version,
    updatedAt: updatedAt ?? this.updatedAt,
    deviceId: deviceId ?? this.deviceId,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
    type: type ?? this.type,
    sourceRef: sourceRef ?? this.sourceRef,
    parentCardId: parentCardId.present ? parentCardId.value : this.parentCardId,
    regeneratedFromId: regeneratedFromId.present
        ? regeneratedFromId.value
        : this.regeneratedFromId,
    contentMd: contentMd ?? this.contentMd,
    sessionId: sessionId.present ? sessionId.value : this.sessionId,
    modelId: modelId.present ? modelId.value : this.modelId,
  );
  CardRow copyWithCompanion(CardsCompanion data) {
    return CardRow(
      id: data.id.present ? data.id.value : this.id,
      version: data.version.present ? data.version.value : this.version,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      type: data.type.present ? data.type.value : this.type,
      sourceRef: data.sourceRef.present ? data.sourceRef.value : this.sourceRef,
      parentCardId: data.parentCardId.present
          ? data.parentCardId.value
          : this.parentCardId,
      regeneratedFromId: data.regeneratedFromId.present
          ? data.regeneratedFromId.value
          : this.regeneratedFromId,
      contentMd: data.contentMd.present ? data.contentMd.value : this.contentMd,
      sessionId: data.sessionId.present ? data.sessionId.value : this.sessionId,
      modelId: data.modelId.present ? data.modelId.value : this.modelId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CardRow(')
          ..write('id: $id, ')
          ..write('version: $version, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deviceId: $deviceId, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('type: $type, ')
          ..write('sourceRef: $sourceRef, ')
          ..write('parentCardId: $parentCardId, ')
          ..write('regeneratedFromId: $regeneratedFromId, ')
          ..write('contentMd: $contentMd, ')
          ..write('sessionId: $sessionId, ')
          ..write('modelId: $modelId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    version,
    updatedAt,
    deviceId,
    deletedAt,
    type,
    sourceRef,
    parentCardId,
    regeneratedFromId,
    contentMd,
    sessionId,
    modelId,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CardRow &&
          other.id == this.id &&
          other.version == this.version &&
          other.updatedAt == this.updatedAt &&
          other.deviceId == this.deviceId &&
          other.deletedAt == this.deletedAt &&
          other.type == this.type &&
          other.sourceRef == this.sourceRef &&
          other.parentCardId == this.parentCardId &&
          other.regeneratedFromId == this.regeneratedFromId &&
          other.contentMd == this.contentMd &&
          other.sessionId == this.sessionId &&
          other.modelId == this.modelId);
}

class CardsCompanion extends UpdateCompanion<CardRow> {
  final Value<String> id;
  final Value<int> version;
  final Value<DateTime> updatedAt;
  final Value<String> deviceId;
  final Value<DateTime?> deletedAt;
  final Value<String> type;
  final Value<String> sourceRef;
  final Value<String?> parentCardId;
  final Value<String?> regeneratedFromId;
  final Value<String> contentMd;
  final Value<String?> sessionId;
  final Value<String?> modelId;
  final Value<int> rowid;
  const CardsCompanion({
    this.id = const Value.absent(),
    this.version = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.type = const Value.absent(),
    this.sourceRef = const Value.absent(),
    this.parentCardId = const Value.absent(),
    this.regeneratedFromId = const Value.absent(),
    this.contentMd = const Value.absent(),
    this.sessionId = const Value.absent(),
    this.modelId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CardsCompanion.insert({
    required String id,
    this.version = const Value.absent(),
    required DateTime updatedAt,
    required String deviceId,
    this.deletedAt = const Value.absent(),
    required String type,
    this.sourceRef = const Value.absent(),
    this.parentCardId = const Value.absent(),
    this.regeneratedFromId = const Value.absent(),
    this.contentMd = const Value.absent(),
    this.sessionId = const Value.absent(),
    this.modelId = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       updatedAt = Value(updatedAt),
       deviceId = Value(deviceId),
       type = Value(type);
  static Insertable<CardRow> custom({
    Expression<String>? id,
    Expression<int>? version,
    Expression<DateTime>? updatedAt,
    Expression<String>? deviceId,
    Expression<DateTime>? deletedAt,
    Expression<String>? type,
    Expression<String>? sourceRef,
    Expression<String>? parentCardId,
    Expression<String>? regeneratedFromId,
    Expression<String>? contentMd,
    Expression<String>? sessionId,
    Expression<String>? modelId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (version != null) 'version': version,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deviceId != null) 'device_id': deviceId,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (type != null) 'type': type,
      if (sourceRef != null) 'source_ref': sourceRef,
      if (parentCardId != null) 'parent_card_id': parentCardId,
      if (regeneratedFromId != null) 'regenerated_from_id': regeneratedFromId,
      if (contentMd != null) 'content_md': contentMd,
      if (sessionId != null) 'session_id': sessionId,
      if (modelId != null) 'model_id': modelId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CardsCompanion copyWith({
    Value<String>? id,
    Value<int>? version,
    Value<DateTime>? updatedAt,
    Value<String>? deviceId,
    Value<DateTime?>? deletedAt,
    Value<String>? type,
    Value<String>? sourceRef,
    Value<String?>? parentCardId,
    Value<String?>? regeneratedFromId,
    Value<String>? contentMd,
    Value<String?>? sessionId,
    Value<String?>? modelId,
    Value<int>? rowid,
  }) {
    return CardsCompanion(
      id: id ?? this.id,
      version: version ?? this.version,
      updatedAt: updatedAt ?? this.updatedAt,
      deviceId: deviceId ?? this.deviceId,
      deletedAt: deletedAt ?? this.deletedAt,
      type: type ?? this.type,
      sourceRef: sourceRef ?? this.sourceRef,
      parentCardId: parentCardId ?? this.parentCardId,
      regeneratedFromId: regeneratedFromId ?? this.regeneratedFromId,
      contentMd: contentMd ?? this.contentMd,
      sessionId: sessionId ?? this.sessionId,
      modelId: modelId ?? this.modelId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (version.present) {
      map['version'] = Variable<int>(version.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (deviceId.present) {
      map['device_id'] = Variable<String>(deviceId.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<DateTime>(deletedAt.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (sourceRef.present) {
      map['source_ref'] = Variable<String>(sourceRef.value);
    }
    if (parentCardId.present) {
      map['parent_card_id'] = Variable<String>(parentCardId.value);
    }
    if (regeneratedFromId.present) {
      map['regenerated_from_id'] = Variable<String>(regeneratedFromId.value);
    }
    if (contentMd.present) {
      map['content_md'] = Variable<String>(contentMd.value);
    }
    if (sessionId.present) {
      map['session_id'] = Variable<String>(sessionId.value);
    }
    if (modelId.present) {
      map['model_id'] = Variable<String>(modelId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CardsCompanion(')
          ..write('id: $id, ')
          ..write('version: $version, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deviceId: $deviceId, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('type: $type, ')
          ..write('sourceRef: $sourceRef, ')
          ..write('parentCardId: $parentCardId, ')
          ..write('regeneratedFromId: $regeneratedFromId, ')
          ..write('contentMd: $contentMd, ')
          ..write('sessionId: $sessionId, ')
          ..write('modelId: $modelId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CanvasesTable extends Canvases
    with TableInfo<$CanvasesTable, CanvasRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CanvasesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _versionMeta = const VerificationMeta(
    'version',
  );
  @override
  late final GeneratedColumn<int> version = GeneratedColumn<int>(
    'version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deviceIdMeta = const VerificationMeta(
    'deviceId',
  );
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
    'device_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<DateTime> deletedAt = GeneratedColumn<DateTime>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _notebookIdMeta = const VerificationMeta(
    'notebookId',
  );
  @override
  late final GeneratedColumn<String> notebookId = GeneratedColumn<String>(
    'notebook_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _viewportMeta = const VerificationMeta(
    'viewport',
  );
  @override
  late final GeneratedColumn<String> viewport = GeneratedColumn<String>(
    'viewport',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('{"x":0,"y":0,"zoom":1}'),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    version,
    updatedAt,
    deviceId,
    deletedAt,
    notebookId,
    name,
    viewport,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'canvases';
  @override
  VerificationContext validateIntegrity(
    Insertable<CanvasRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('version')) {
      context.handle(
        _versionMeta,
        version.isAcceptableOrUnknown(data['version']!, _versionMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('device_id')) {
      context.handle(
        _deviceIdMeta,
        deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_deviceIdMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    if (data.containsKey('notebook_id')) {
      context.handle(
        _notebookIdMeta,
        notebookId.isAcceptableOrUnknown(data['notebook_id']!, _notebookIdMeta),
      );
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    }
    if (data.containsKey('viewport')) {
      context.handle(
        _viewportMeta,
        viewport.isAcceptableOrUnknown(data['viewport']!, _viewportMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  CanvasRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CanvasRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      version: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}version'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      deviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}device_id'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}deleted_at'],
      ),
      notebookId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}notebook_id'],
      ),
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      viewport: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}viewport'],
      )!,
    );
  }

  @override
  $CanvasesTable createAlias(String alias) {
    return $CanvasesTable(attachedDatabase, alias);
  }
}

class CanvasRow extends DataClass implements Insertable<CanvasRow> {
  /// ULID 主键。
  final String id;

  /// 本地递增版本号，服务端接管后用于 LWW 冲突判定。
  final int version;
  final DateTime updatedAt;

  /// 产生该次变更的设备，用于同步自回声过滤。
  final String deviceId;

  /// tombstone 软删除：非空即删除，删除靠它传播，不物理删（§11）。
  final DateTime? deletedAt;
  final String? notebookId;
  final String name;

  /// 视口 {x,y,zoom} 的 JSON。
  final String viewport;
  const CanvasRow({
    required this.id,
    required this.version,
    required this.updatedAt,
    required this.deviceId,
    this.deletedAt,
    this.notebookId,
    required this.name,
    required this.viewport,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['version'] = Variable<int>(version);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    map['device_id'] = Variable<String>(deviceId);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<DateTime>(deletedAt);
    }
    if (!nullToAbsent || notebookId != null) {
      map['notebook_id'] = Variable<String>(notebookId);
    }
    map['name'] = Variable<String>(name);
    map['viewport'] = Variable<String>(viewport);
    return map;
  }

  CanvasesCompanion toCompanion(bool nullToAbsent) {
    return CanvasesCompanion(
      id: Value(id),
      version: Value(version),
      updatedAt: Value(updatedAt),
      deviceId: Value(deviceId),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
      notebookId: notebookId == null && nullToAbsent
          ? const Value.absent()
          : Value(notebookId),
      name: Value(name),
      viewport: Value(viewport),
    );
  }

  factory CanvasRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CanvasRow(
      id: serializer.fromJson<String>(json['id']),
      version: serializer.fromJson<int>(json['version']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      deviceId: serializer.fromJson<String>(json['deviceId']),
      deletedAt: serializer.fromJson<DateTime?>(json['deletedAt']),
      notebookId: serializer.fromJson<String?>(json['notebookId']),
      name: serializer.fromJson<String>(json['name']),
      viewport: serializer.fromJson<String>(json['viewport']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'version': serializer.toJson<int>(version),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'deviceId': serializer.toJson<String>(deviceId),
      'deletedAt': serializer.toJson<DateTime?>(deletedAt),
      'notebookId': serializer.toJson<String?>(notebookId),
      'name': serializer.toJson<String>(name),
      'viewport': serializer.toJson<String>(viewport),
    };
  }

  CanvasRow copyWith({
    String? id,
    int? version,
    DateTime? updatedAt,
    String? deviceId,
    Value<DateTime?> deletedAt = const Value.absent(),
    Value<String?> notebookId = const Value.absent(),
    String? name,
    String? viewport,
  }) => CanvasRow(
    id: id ?? this.id,
    version: version ?? this.version,
    updatedAt: updatedAt ?? this.updatedAt,
    deviceId: deviceId ?? this.deviceId,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
    notebookId: notebookId.present ? notebookId.value : this.notebookId,
    name: name ?? this.name,
    viewport: viewport ?? this.viewport,
  );
  CanvasRow copyWithCompanion(CanvasesCompanion data) {
    return CanvasRow(
      id: data.id.present ? data.id.value : this.id,
      version: data.version.present ? data.version.value : this.version,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      notebookId: data.notebookId.present
          ? data.notebookId.value
          : this.notebookId,
      name: data.name.present ? data.name.value : this.name,
      viewport: data.viewport.present ? data.viewport.value : this.viewport,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CanvasRow(')
          ..write('id: $id, ')
          ..write('version: $version, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deviceId: $deviceId, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('notebookId: $notebookId, ')
          ..write('name: $name, ')
          ..write('viewport: $viewport')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    version,
    updatedAt,
    deviceId,
    deletedAt,
    notebookId,
    name,
    viewport,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CanvasRow &&
          other.id == this.id &&
          other.version == this.version &&
          other.updatedAt == this.updatedAt &&
          other.deviceId == this.deviceId &&
          other.deletedAt == this.deletedAt &&
          other.notebookId == this.notebookId &&
          other.name == this.name &&
          other.viewport == this.viewport);
}

class CanvasesCompanion extends UpdateCompanion<CanvasRow> {
  final Value<String> id;
  final Value<int> version;
  final Value<DateTime> updatedAt;
  final Value<String> deviceId;
  final Value<DateTime?> deletedAt;
  final Value<String?> notebookId;
  final Value<String> name;
  final Value<String> viewport;
  final Value<int> rowid;
  const CanvasesCompanion({
    this.id = const Value.absent(),
    this.version = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.notebookId = const Value.absent(),
    this.name = const Value.absent(),
    this.viewport = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CanvasesCompanion.insert({
    required String id,
    this.version = const Value.absent(),
    required DateTime updatedAt,
    required String deviceId,
    this.deletedAt = const Value.absent(),
    this.notebookId = const Value.absent(),
    this.name = const Value.absent(),
    this.viewport = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       updatedAt = Value(updatedAt),
       deviceId = Value(deviceId);
  static Insertable<CanvasRow> custom({
    Expression<String>? id,
    Expression<int>? version,
    Expression<DateTime>? updatedAt,
    Expression<String>? deviceId,
    Expression<DateTime>? deletedAt,
    Expression<String>? notebookId,
    Expression<String>? name,
    Expression<String>? viewport,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (version != null) 'version': version,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deviceId != null) 'device_id': deviceId,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (notebookId != null) 'notebook_id': notebookId,
      if (name != null) 'name': name,
      if (viewport != null) 'viewport': viewport,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CanvasesCompanion copyWith({
    Value<String>? id,
    Value<int>? version,
    Value<DateTime>? updatedAt,
    Value<String>? deviceId,
    Value<DateTime?>? deletedAt,
    Value<String?>? notebookId,
    Value<String>? name,
    Value<String>? viewport,
    Value<int>? rowid,
  }) {
    return CanvasesCompanion(
      id: id ?? this.id,
      version: version ?? this.version,
      updatedAt: updatedAt ?? this.updatedAt,
      deviceId: deviceId ?? this.deviceId,
      deletedAt: deletedAt ?? this.deletedAt,
      notebookId: notebookId ?? this.notebookId,
      name: name ?? this.name,
      viewport: viewport ?? this.viewport,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (version.present) {
      map['version'] = Variable<int>(version.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (deviceId.present) {
      map['device_id'] = Variable<String>(deviceId.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<DateTime>(deletedAt.value);
    }
    if (notebookId.present) {
      map['notebook_id'] = Variable<String>(notebookId.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (viewport.present) {
      map['viewport'] = Variable<String>(viewport.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CanvasesCompanion(')
          ..write('id: $id, ')
          ..write('version: $version, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deviceId: $deviceId, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('notebookId: $notebookId, ')
          ..write('name: $name, ')
          ..write('viewport: $viewport, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CanvasNodesTable extends CanvasNodes
    with TableInfo<$CanvasNodesTable, CanvasNodeRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CanvasNodesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _versionMeta = const VerificationMeta(
    'version',
  );
  @override
  late final GeneratedColumn<int> version = GeneratedColumn<int>(
    'version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deviceIdMeta = const VerificationMeta(
    'deviceId',
  );
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
    'device_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<DateTime> deletedAt = GeneratedColumn<DateTime>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _canvasIdMeta = const VerificationMeta(
    'canvasId',
  );
  @override
  late final GeneratedColumn<String> canvasId = GeneratedColumn<String>(
    'canvas_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _targetTypeMeta = const VerificationMeta(
    'targetType',
  );
  @override
  late final GeneratedColumn<String> targetType = GeneratedColumn<String>(
    'target_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _targetIdMeta = const VerificationMeta(
    'targetId',
  );
  @override
  late final GeneratedColumn<String> targetId = GeneratedColumn<String>(
    'target_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _xMeta = const VerificationMeta('x');
  @override
  late final GeneratedColumn<double> x = GeneratedColumn<double>(
    'x',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _yMeta = const VerificationMeta('y');
  @override
  late final GeneratedColumn<double> y = GeneratedColumn<double>(
    'y',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _wMeta = const VerificationMeta('w');
  @override
  late final GeneratedColumn<double> w = GeneratedColumn<double>(
    'w',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    defaultValue: const Constant(200),
  );
  static const VerificationMeta _hMeta = const VerificationMeta('h');
  @override
  late final GeneratedColumn<double> h = GeneratedColumn<double>(
    'h',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    defaultValue: const Constant(120),
  );
  static const VerificationMeta _zMeta = const VerificationMeta('z');
  @override
  late final GeneratedColumn<int> z = GeneratedColumn<int>(
    'z',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _collapsedMeta = const VerificationMeta(
    'collapsed',
  );
  @override
  late final GeneratedColumn<bool> collapsed = GeneratedColumn<bool>(
    'collapsed',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("collapsed" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _pinnedMeta = const VerificationMeta('pinned');
  @override
  late final GeneratedColumn<bool> pinned = GeneratedColumn<bool>(
    'pinned',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("pinned" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    version,
    updatedAt,
    deviceId,
    deletedAt,
    canvasId,
    targetType,
    targetId,
    x,
    y,
    w,
    h,
    z,
    collapsed,
    pinned,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'canvas_nodes';
  @override
  VerificationContext validateIntegrity(
    Insertable<CanvasNodeRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('version')) {
      context.handle(
        _versionMeta,
        version.isAcceptableOrUnknown(data['version']!, _versionMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('device_id')) {
      context.handle(
        _deviceIdMeta,
        deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_deviceIdMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    if (data.containsKey('canvas_id')) {
      context.handle(
        _canvasIdMeta,
        canvasId.isAcceptableOrUnknown(data['canvas_id']!, _canvasIdMeta),
      );
    } else if (isInserting) {
      context.missing(_canvasIdMeta);
    }
    if (data.containsKey('target_type')) {
      context.handle(
        _targetTypeMeta,
        targetType.isAcceptableOrUnknown(data['target_type']!, _targetTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_targetTypeMeta);
    }
    if (data.containsKey('target_id')) {
      context.handle(
        _targetIdMeta,
        targetId.isAcceptableOrUnknown(data['target_id']!, _targetIdMeta),
      );
    } else if (isInserting) {
      context.missing(_targetIdMeta);
    }
    if (data.containsKey('x')) {
      context.handle(_xMeta, x.isAcceptableOrUnknown(data['x']!, _xMeta));
    }
    if (data.containsKey('y')) {
      context.handle(_yMeta, y.isAcceptableOrUnknown(data['y']!, _yMeta));
    }
    if (data.containsKey('w')) {
      context.handle(_wMeta, w.isAcceptableOrUnknown(data['w']!, _wMeta));
    }
    if (data.containsKey('h')) {
      context.handle(_hMeta, h.isAcceptableOrUnknown(data['h']!, _hMeta));
    }
    if (data.containsKey('z')) {
      context.handle(_zMeta, z.isAcceptableOrUnknown(data['z']!, _zMeta));
    }
    if (data.containsKey('collapsed')) {
      context.handle(
        _collapsedMeta,
        collapsed.isAcceptableOrUnknown(data['collapsed']!, _collapsedMeta),
      );
    }
    if (data.containsKey('pinned')) {
      context.handle(
        _pinnedMeta,
        pinned.isAcceptableOrUnknown(data['pinned']!, _pinnedMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  CanvasNodeRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CanvasNodeRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      version: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}version'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      deviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}device_id'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}deleted_at'],
      ),
      canvasId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}canvas_id'],
      )!,
      targetType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}target_type'],
      )!,
      targetId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}target_id'],
      )!,
      x: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}x'],
      )!,
      y: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}y'],
      )!,
      w: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}w'],
      )!,
      h: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}h'],
      )!,
      z: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}z'],
      )!,
      collapsed: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}collapsed'],
      )!,
      pinned: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}pinned'],
      )!,
    );
  }

  @override
  $CanvasNodesTable createAlias(String alias) {
    return $CanvasNodesTable(attachedDatabase, alias);
  }
}

class CanvasNodeRow extends DataClass implements Insertable<CanvasNodeRow> {
  /// ULID 主键。
  final String id;

  /// 本地递增版本号，服务端接管后用于 LWW 冲突判定。
  final int version;
  final DateTime updatedAt;

  /// 产生该次变更的设备，用于同步自回声过滤。
  final String deviceId;

  /// tombstone 软删除：非空即删除，删除靠它传播，不物理删（§11）。
  final DateTime? deletedAt;
  final String canvasId;

  /// note/kp/card/group。
  final String targetType;
  final String targetId;
  final double x;
  final double y;
  final double w;
  final double h;
  final int z;
  final bool collapsed;

  /// 是否锁定：true = 用户拖过 / 已固化，结构变化（增删边）的自动重排**不**移动它；
  /// false = 浮动节点，结构变化时由布局引擎自动重新铺位。
  /// 默认 true（历史数据 + 手动固化都按「已锁定」处理，除非显式置 false）。
  final bool pinned;
  const CanvasNodeRow({
    required this.id,
    required this.version,
    required this.updatedAt,
    required this.deviceId,
    this.deletedAt,
    required this.canvasId,
    required this.targetType,
    required this.targetId,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.z,
    required this.collapsed,
    required this.pinned,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['version'] = Variable<int>(version);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    map['device_id'] = Variable<String>(deviceId);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<DateTime>(deletedAt);
    }
    map['canvas_id'] = Variable<String>(canvasId);
    map['target_type'] = Variable<String>(targetType);
    map['target_id'] = Variable<String>(targetId);
    map['x'] = Variable<double>(x);
    map['y'] = Variable<double>(y);
    map['w'] = Variable<double>(w);
    map['h'] = Variable<double>(h);
    map['z'] = Variable<int>(z);
    map['collapsed'] = Variable<bool>(collapsed);
    map['pinned'] = Variable<bool>(pinned);
    return map;
  }

  CanvasNodesCompanion toCompanion(bool nullToAbsent) {
    return CanvasNodesCompanion(
      id: Value(id),
      version: Value(version),
      updatedAt: Value(updatedAt),
      deviceId: Value(deviceId),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
      canvasId: Value(canvasId),
      targetType: Value(targetType),
      targetId: Value(targetId),
      x: Value(x),
      y: Value(y),
      w: Value(w),
      h: Value(h),
      z: Value(z),
      collapsed: Value(collapsed),
      pinned: Value(pinned),
    );
  }

  factory CanvasNodeRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CanvasNodeRow(
      id: serializer.fromJson<String>(json['id']),
      version: serializer.fromJson<int>(json['version']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      deviceId: serializer.fromJson<String>(json['deviceId']),
      deletedAt: serializer.fromJson<DateTime?>(json['deletedAt']),
      canvasId: serializer.fromJson<String>(json['canvasId']),
      targetType: serializer.fromJson<String>(json['targetType']),
      targetId: serializer.fromJson<String>(json['targetId']),
      x: serializer.fromJson<double>(json['x']),
      y: serializer.fromJson<double>(json['y']),
      w: serializer.fromJson<double>(json['w']),
      h: serializer.fromJson<double>(json['h']),
      z: serializer.fromJson<int>(json['z']),
      collapsed: serializer.fromJson<bool>(json['collapsed']),
      pinned: serializer.fromJson<bool>(json['pinned']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'version': serializer.toJson<int>(version),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'deviceId': serializer.toJson<String>(deviceId),
      'deletedAt': serializer.toJson<DateTime?>(deletedAt),
      'canvasId': serializer.toJson<String>(canvasId),
      'targetType': serializer.toJson<String>(targetType),
      'targetId': serializer.toJson<String>(targetId),
      'x': serializer.toJson<double>(x),
      'y': serializer.toJson<double>(y),
      'w': serializer.toJson<double>(w),
      'h': serializer.toJson<double>(h),
      'z': serializer.toJson<int>(z),
      'collapsed': serializer.toJson<bool>(collapsed),
      'pinned': serializer.toJson<bool>(pinned),
    };
  }

  CanvasNodeRow copyWith({
    String? id,
    int? version,
    DateTime? updatedAt,
    String? deviceId,
    Value<DateTime?> deletedAt = const Value.absent(),
    String? canvasId,
    String? targetType,
    String? targetId,
    double? x,
    double? y,
    double? w,
    double? h,
    int? z,
    bool? collapsed,
    bool? pinned,
  }) => CanvasNodeRow(
    id: id ?? this.id,
    version: version ?? this.version,
    updatedAt: updatedAt ?? this.updatedAt,
    deviceId: deviceId ?? this.deviceId,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
    canvasId: canvasId ?? this.canvasId,
    targetType: targetType ?? this.targetType,
    targetId: targetId ?? this.targetId,
    x: x ?? this.x,
    y: y ?? this.y,
    w: w ?? this.w,
    h: h ?? this.h,
    z: z ?? this.z,
    collapsed: collapsed ?? this.collapsed,
    pinned: pinned ?? this.pinned,
  );
  CanvasNodeRow copyWithCompanion(CanvasNodesCompanion data) {
    return CanvasNodeRow(
      id: data.id.present ? data.id.value : this.id,
      version: data.version.present ? data.version.value : this.version,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      canvasId: data.canvasId.present ? data.canvasId.value : this.canvasId,
      targetType: data.targetType.present
          ? data.targetType.value
          : this.targetType,
      targetId: data.targetId.present ? data.targetId.value : this.targetId,
      x: data.x.present ? data.x.value : this.x,
      y: data.y.present ? data.y.value : this.y,
      w: data.w.present ? data.w.value : this.w,
      h: data.h.present ? data.h.value : this.h,
      z: data.z.present ? data.z.value : this.z,
      collapsed: data.collapsed.present ? data.collapsed.value : this.collapsed,
      pinned: data.pinned.present ? data.pinned.value : this.pinned,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CanvasNodeRow(')
          ..write('id: $id, ')
          ..write('version: $version, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deviceId: $deviceId, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('canvasId: $canvasId, ')
          ..write('targetType: $targetType, ')
          ..write('targetId: $targetId, ')
          ..write('x: $x, ')
          ..write('y: $y, ')
          ..write('w: $w, ')
          ..write('h: $h, ')
          ..write('z: $z, ')
          ..write('collapsed: $collapsed, ')
          ..write('pinned: $pinned')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    version,
    updatedAt,
    deviceId,
    deletedAt,
    canvasId,
    targetType,
    targetId,
    x,
    y,
    w,
    h,
    z,
    collapsed,
    pinned,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CanvasNodeRow &&
          other.id == this.id &&
          other.version == this.version &&
          other.updatedAt == this.updatedAt &&
          other.deviceId == this.deviceId &&
          other.deletedAt == this.deletedAt &&
          other.canvasId == this.canvasId &&
          other.targetType == this.targetType &&
          other.targetId == this.targetId &&
          other.x == this.x &&
          other.y == this.y &&
          other.w == this.w &&
          other.h == this.h &&
          other.z == this.z &&
          other.collapsed == this.collapsed &&
          other.pinned == this.pinned);
}

class CanvasNodesCompanion extends UpdateCompanion<CanvasNodeRow> {
  final Value<String> id;
  final Value<int> version;
  final Value<DateTime> updatedAt;
  final Value<String> deviceId;
  final Value<DateTime?> deletedAt;
  final Value<String> canvasId;
  final Value<String> targetType;
  final Value<String> targetId;
  final Value<double> x;
  final Value<double> y;
  final Value<double> w;
  final Value<double> h;
  final Value<int> z;
  final Value<bool> collapsed;
  final Value<bool> pinned;
  final Value<int> rowid;
  const CanvasNodesCompanion({
    this.id = const Value.absent(),
    this.version = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.canvasId = const Value.absent(),
    this.targetType = const Value.absent(),
    this.targetId = const Value.absent(),
    this.x = const Value.absent(),
    this.y = const Value.absent(),
    this.w = const Value.absent(),
    this.h = const Value.absent(),
    this.z = const Value.absent(),
    this.collapsed = const Value.absent(),
    this.pinned = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CanvasNodesCompanion.insert({
    required String id,
    this.version = const Value.absent(),
    required DateTime updatedAt,
    required String deviceId,
    this.deletedAt = const Value.absent(),
    required String canvasId,
    required String targetType,
    required String targetId,
    this.x = const Value.absent(),
    this.y = const Value.absent(),
    this.w = const Value.absent(),
    this.h = const Value.absent(),
    this.z = const Value.absent(),
    this.collapsed = const Value.absent(),
    this.pinned = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       updatedAt = Value(updatedAt),
       deviceId = Value(deviceId),
       canvasId = Value(canvasId),
       targetType = Value(targetType),
       targetId = Value(targetId);
  static Insertable<CanvasNodeRow> custom({
    Expression<String>? id,
    Expression<int>? version,
    Expression<DateTime>? updatedAt,
    Expression<String>? deviceId,
    Expression<DateTime>? deletedAt,
    Expression<String>? canvasId,
    Expression<String>? targetType,
    Expression<String>? targetId,
    Expression<double>? x,
    Expression<double>? y,
    Expression<double>? w,
    Expression<double>? h,
    Expression<int>? z,
    Expression<bool>? collapsed,
    Expression<bool>? pinned,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (version != null) 'version': version,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deviceId != null) 'device_id': deviceId,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (canvasId != null) 'canvas_id': canvasId,
      if (targetType != null) 'target_type': targetType,
      if (targetId != null) 'target_id': targetId,
      if (x != null) 'x': x,
      if (y != null) 'y': y,
      if (w != null) 'w': w,
      if (h != null) 'h': h,
      if (z != null) 'z': z,
      if (collapsed != null) 'collapsed': collapsed,
      if (pinned != null) 'pinned': pinned,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CanvasNodesCompanion copyWith({
    Value<String>? id,
    Value<int>? version,
    Value<DateTime>? updatedAt,
    Value<String>? deviceId,
    Value<DateTime?>? deletedAt,
    Value<String>? canvasId,
    Value<String>? targetType,
    Value<String>? targetId,
    Value<double>? x,
    Value<double>? y,
    Value<double>? w,
    Value<double>? h,
    Value<int>? z,
    Value<bool>? collapsed,
    Value<bool>? pinned,
    Value<int>? rowid,
  }) {
    return CanvasNodesCompanion(
      id: id ?? this.id,
      version: version ?? this.version,
      updatedAt: updatedAt ?? this.updatedAt,
      deviceId: deviceId ?? this.deviceId,
      deletedAt: deletedAt ?? this.deletedAt,
      canvasId: canvasId ?? this.canvasId,
      targetType: targetType ?? this.targetType,
      targetId: targetId ?? this.targetId,
      x: x ?? this.x,
      y: y ?? this.y,
      w: w ?? this.w,
      h: h ?? this.h,
      z: z ?? this.z,
      collapsed: collapsed ?? this.collapsed,
      pinned: pinned ?? this.pinned,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (version.present) {
      map['version'] = Variable<int>(version.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (deviceId.present) {
      map['device_id'] = Variable<String>(deviceId.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<DateTime>(deletedAt.value);
    }
    if (canvasId.present) {
      map['canvas_id'] = Variable<String>(canvasId.value);
    }
    if (targetType.present) {
      map['target_type'] = Variable<String>(targetType.value);
    }
    if (targetId.present) {
      map['target_id'] = Variable<String>(targetId.value);
    }
    if (x.present) {
      map['x'] = Variable<double>(x.value);
    }
    if (y.present) {
      map['y'] = Variable<double>(y.value);
    }
    if (w.present) {
      map['w'] = Variable<double>(w.value);
    }
    if (h.present) {
      map['h'] = Variable<double>(h.value);
    }
    if (z.present) {
      map['z'] = Variable<int>(z.value);
    }
    if (collapsed.present) {
      map['collapsed'] = Variable<bool>(collapsed.value);
    }
    if (pinned.present) {
      map['pinned'] = Variable<bool>(pinned.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CanvasNodesCompanion(')
          ..write('id: $id, ')
          ..write('version: $version, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deviceId: $deviceId, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('canvasId: $canvasId, ')
          ..write('targetType: $targetType, ')
          ..write('targetId: $targetId, ')
          ..write('x: $x, ')
          ..write('y: $y, ')
          ..write('w: $w, ')
          ..write('h: $h, ')
          ..write('z: $z, ')
          ..write('collapsed: $collapsed, ')
          ..write('pinned: $pinned, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CanvasEdgesTable extends CanvasEdges
    with TableInfo<$CanvasEdgesTable, CanvasEdgeRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CanvasEdgesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _versionMeta = const VerificationMeta(
    'version',
  );
  @override
  late final GeneratedColumn<int> version = GeneratedColumn<int>(
    'version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deviceIdMeta = const VerificationMeta(
    'deviceId',
  );
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
    'device_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<DateTime> deletedAt = GeneratedColumn<DateTime>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _canvasIdMeta = const VerificationMeta(
    'canvasId',
  );
  @override
  late final GeneratedColumn<String> canvasId = GeneratedColumn<String>(
    'canvas_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _fromNodeIdMeta = const VerificationMeta(
    'fromNodeId',
  );
  @override
  late final GeneratedColumn<String> fromNodeId = GeneratedColumn<String>(
    'from_node_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _toNodeIdMeta = const VerificationMeta(
    'toNodeId',
  );
  @override
  late final GeneratedColumn<String> toNodeId = GeneratedColumn<String>(
    'to_node_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _edgeTypeMeta = const VerificationMeta(
    'edgeType',
  );
  @override
  late final GeneratedColumn<String> edgeType = GeneratedColumn<String>(
    'edge_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('manual'),
  );
  static const VerificationMeta _prereqEdgeIdMeta = const VerificationMeta(
    'prereqEdgeId',
  );
  @override
  late final GeneratedColumn<String> prereqEdgeId = GeneratedColumn<String>(
    'prereq_edge_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    version,
    updatedAt,
    deviceId,
    deletedAt,
    canvasId,
    fromNodeId,
    toNodeId,
    edgeType,
    prereqEdgeId,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'canvas_edges';
  @override
  VerificationContext validateIntegrity(
    Insertable<CanvasEdgeRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('version')) {
      context.handle(
        _versionMeta,
        version.isAcceptableOrUnknown(data['version']!, _versionMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('device_id')) {
      context.handle(
        _deviceIdMeta,
        deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_deviceIdMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    if (data.containsKey('canvas_id')) {
      context.handle(
        _canvasIdMeta,
        canvasId.isAcceptableOrUnknown(data['canvas_id']!, _canvasIdMeta),
      );
    } else if (isInserting) {
      context.missing(_canvasIdMeta);
    }
    if (data.containsKey('from_node_id')) {
      context.handle(
        _fromNodeIdMeta,
        fromNodeId.isAcceptableOrUnknown(
          data['from_node_id']!,
          _fromNodeIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_fromNodeIdMeta);
    }
    if (data.containsKey('to_node_id')) {
      context.handle(
        _toNodeIdMeta,
        toNodeId.isAcceptableOrUnknown(data['to_node_id']!, _toNodeIdMeta),
      );
    } else if (isInserting) {
      context.missing(_toNodeIdMeta);
    }
    if (data.containsKey('edge_type')) {
      context.handle(
        _edgeTypeMeta,
        edgeType.isAcceptableOrUnknown(data['edge_type']!, _edgeTypeMeta),
      );
    }
    if (data.containsKey('prereq_edge_id')) {
      context.handle(
        _prereqEdgeIdMeta,
        prereqEdgeId.isAcceptableOrUnknown(
          data['prereq_edge_id']!,
          _prereqEdgeIdMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  CanvasEdgeRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CanvasEdgeRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      version: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}version'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      deviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}device_id'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}deleted_at'],
      ),
      canvasId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}canvas_id'],
      )!,
      fromNodeId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}from_node_id'],
      )!,
      toNodeId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}to_node_id'],
      )!,
      edgeType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}edge_type'],
      )!,
      prereqEdgeId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}prereq_edge_id'],
      ),
    );
  }

  @override
  $CanvasEdgesTable createAlias(String alias) {
    return $CanvasEdgesTable(attachedDatabase, alias);
  }
}

class CanvasEdgeRow extends DataClass implements Insertable<CanvasEdgeRow> {
  /// ULID 主键。
  final String id;

  /// 本地递增版本号，服务端接管后用于 LWW 冲突判定。
  final int version;
  final DateTime updatedAt;

  /// 产生该次变更的设备，用于同步自回声过滤。
  final String deviceId;

  /// tombstone 软删除：非空即删除，删除靠它传播，不物理删（§11）。
  final DateTime? deletedAt;
  final String canvasId;
  final String fromNodeId;
  final String toNodeId;

  /// semantic_prereq/attachment/manual。
  final String edgeType;
  final String? prereqEdgeId;
  const CanvasEdgeRow({
    required this.id,
    required this.version,
    required this.updatedAt,
    required this.deviceId,
    this.deletedAt,
    required this.canvasId,
    required this.fromNodeId,
    required this.toNodeId,
    required this.edgeType,
    this.prereqEdgeId,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['version'] = Variable<int>(version);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    map['device_id'] = Variable<String>(deviceId);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<DateTime>(deletedAt);
    }
    map['canvas_id'] = Variable<String>(canvasId);
    map['from_node_id'] = Variable<String>(fromNodeId);
    map['to_node_id'] = Variable<String>(toNodeId);
    map['edge_type'] = Variable<String>(edgeType);
    if (!nullToAbsent || prereqEdgeId != null) {
      map['prereq_edge_id'] = Variable<String>(prereqEdgeId);
    }
    return map;
  }

  CanvasEdgesCompanion toCompanion(bool nullToAbsent) {
    return CanvasEdgesCompanion(
      id: Value(id),
      version: Value(version),
      updatedAt: Value(updatedAt),
      deviceId: Value(deviceId),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
      canvasId: Value(canvasId),
      fromNodeId: Value(fromNodeId),
      toNodeId: Value(toNodeId),
      edgeType: Value(edgeType),
      prereqEdgeId: prereqEdgeId == null && nullToAbsent
          ? const Value.absent()
          : Value(prereqEdgeId),
    );
  }

  factory CanvasEdgeRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CanvasEdgeRow(
      id: serializer.fromJson<String>(json['id']),
      version: serializer.fromJson<int>(json['version']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      deviceId: serializer.fromJson<String>(json['deviceId']),
      deletedAt: serializer.fromJson<DateTime?>(json['deletedAt']),
      canvasId: serializer.fromJson<String>(json['canvasId']),
      fromNodeId: serializer.fromJson<String>(json['fromNodeId']),
      toNodeId: serializer.fromJson<String>(json['toNodeId']),
      edgeType: serializer.fromJson<String>(json['edgeType']),
      prereqEdgeId: serializer.fromJson<String?>(json['prereqEdgeId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'version': serializer.toJson<int>(version),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'deviceId': serializer.toJson<String>(deviceId),
      'deletedAt': serializer.toJson<DateTime?>(deletedAt),
      'canvasId': serializer.toJson<String>(canvasId),
      'fromNodeId': serializer.toJson<String>(fromNodeId),
      'toNodeId': serializer.toJson<String>(toNodeId),
      'edgeType': serializer.toJson<String>(edgeType),
      'prereqEdgeId': serializer.toJson<String?>(prereqEdgeId),
    };
  }

  CanvasEdgeRow copyWith({
    String? id,
    int? version,
    DateTime? updatedAt,
    String? deviceId,
    Value<DateTime?> deletedAt = const Value.absent(),
    String? canvasId,
    String? fromNodeId,
    String? toNodeId,
    String? edgeType,
    Value<String?> prereqEdgeId = const Value.absent(),
  }) => CanvasEdgeRow(
    id: id ?? this.id,
    version: version ?? this.version,
    updatedAt: updatedAt ?? this.updatedAt,
    deviceId: deviceId ?? this.deviceId,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
    canvasId: canvasId ?? this.canvasId,
    fromNodeId: fromNodeId ?? this.fromNodeId,
    toNodeId: toNodeId ?? this.toNodeId,
    edgeType: edgeType ?? this.edgeType,
    prereqEdgeId: prereqEdgeId.present ? prereqEdgeId.value : this.prereqEdgeId,
  );
  CanvasEdgeRow copyWithCompanion(CanvasEdgesCompanion data) {
    return CanvasEdgeRow(
      id: data.id.present ? data.id.value : this.id,
      version: data.version.present ? data.version.value : this.version,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      canvasId: data.canvasId.present ? data.canvasId.value : this.canvasId,
      fromNodeId: data.fromNodeId.present
          ? data.fromNodeId.value
          : this.fromNodeId,
      toNodeId: data.toNodeId.present ? data.toNodeId.value : this.toNodeId,
      edgeType: data.edgeType.present ? data.edgeType.value : this.edgeType,
      prereqEdgeId: data.prereqEdgeId.present
          ? data.prereqEdgeId.value
          : this.prereqEdgeId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CanvasEdgeRow(')
          ..write('id: $id, ')
          ..write('version: $version, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deviceId: $deviceId, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('canvasId: $canvasId, ')
          ..write('fromNodeId: $fromNodeId, ')
          ..write('toNodeId: $toNodeId, ')
          ..write('edgeType: $edgeType, ')
          ..write('prereqEdgeId: $prereqEdgeId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    version,
    updatedAt,
    deviceId,
    deletedAt,
    canvasId,
    fromNodeId,
    toNodeId,
    edgeType,
    prereqEdgeId,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CanvasEdgeRow &&
          other.id == this.id &&
          other.version == this.version &&
          other.updatedAt == this.updatedAt &&
          other.deviceId == this.deviceId &&
          other.deletedAt == this.deletedAt &&
          other.canvasId == this.canvasId &&
          other.fromNodeId == this.fromNodeId &&
          other.toNodeId == this.toNodeId &&
          other.edgeType == this.edgeType &&
          other.prereqEdgeId == this.prereqEdgeId);
}

class CanvasEdgesCompanion extends UpdateCompanion<CanvasEdgeRow> {
  final Value<String> id;
  final Value<int> version;
  final Value<DateTime> updatedAt;
  final Value<String> deviceId;
  final Value<DateTime?> deletedAt;
  final Value<String> canvasId;
  final Value<String> fromNodeId;
  final Value<String> toNodeId;
  final Value<String> edgeType;
  final Value<String?> prereqEdgeId;
  final Value<int> rowid;
  const CanvasEdgesCompanion({
    this.id = const Value.absent(),
    this.version = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.canvasId = const Value.absent(),
    this.fromNodeId = const Value.absent(),
    this.toNodeId = const Value.absent(),
    this.edgeType = const Value.absent(),
    this.prereqEdgeId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CanvasEdgesCompanion.insert({
    required String id,
    this.version = const Value.absent(),
    required DateTime updatedAt,
    required String deviceId,
    this.deletedAt = const Value.absent(),
    required String canvasId,
    required String fromNodeId,
    required String toNodeId,
    this.edgeType = const Value.absent(),
    this.prereqEdgeId = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       updatedAt = Value(updatedAt),
       deviceId = Value(deviceId),
       canvasId = Value(canvasId),
       fromNodeId = Value(fromNodeId),
       toNodeId = Value(toNodeId);
  static Insertable<CanvasEdgeRow> custom({
    Expression<String>? id,
    Expression<int>? version,
    Expression<DateTime>? updatedAt,
    Expression<String>? deviceId,
    Expression<DateTime>? deletedAt,
    Expression<String>? canvasId,
    Expression<String>? fromNodeId,
    Expression<String>? toNodeId,
    Expression<String>? edgeType,
    Expression<String>? prereqEdgeId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (version != null) 'version': version,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deviceId != null) 'device_id': deviceId,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (canvasId != null) 'canvas_id': canvasId,
      if (fromNodeId != null) 'from_node_id': fromNodeId,
      if (toNodeId != null) 'to_node_id': toNodeId,
      if (edgeType != null) 'edge_type': edgeType,
      if (prereqEdgeId != null) 'prereq_edge_id': prereqEdgeId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CanvasEdgesCompanion copyWith({
    Value<String>? id,
    Value<int>? version,
    Value<DateTime>? updatedAt,
    Value<String>? deviceId,
    Value<DateTime?>? deletedAt,
    Value<String>? canvasId,
    Value<String>? fromNodeId,
    Value<String>? toNodeId,
    Value<String>? edgeType,
    Value<String?>? prereqEdgeId,
    Value<int>? rowid,
  }) {
    return CanvasEdgesCompanion(
      id: id ?? this.id,
      version: version ?? this.version,
      updatedAt: updatedAt ?? this.updatedAt,
      deviceId: deviceId ?? this.deviceId,
      deletedAt: deletedAt ?? this.deletedAt,
      canvasId: canvasId ?? this.canvasId,
      fromNodeId: fromNodeId ?? this.fromNodeId,
      toNodeId: toNodeId ?? this.toNodeId,
      edgeType: edgeType ?? this.edgeType,
      prereqEdgeId: prereqEdgeId ?? this.prereqEdgeId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (version.present) {
      map['version'] = Variable<int>(version.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (deviceId.present) {
      map['device_id'] = Variable<String>(deviceId.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<DateTime>(deletedAt.value);
    }
    if (canvasId.present) {
      map['canvas_id'] = Variable<String>(canvasId.value);
    }
    if (fromNodeId.present) {
      map['from_node_id'] = Variable<String>(fromNodeId.value);
    }
    if (toNodeId.present) {
      map['to_node_id'] = Variable<String>(toNodeId.value);
    }
    if (edgeType.present) {
      map['edge_type'] = Variable<String>(edgeType.value);
    }
    if (prereqEdgeId.present) {
      map['prereq_edge_id'] = Variable<String>(prereqEdgeId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CanvasEdgesCompanion(')
          ..write('id: $id, ')
          ..write('version: $version, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deviceId: $deviceId, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('canvasId: $canvasId, ')
          ..write('fromNodeId: $fromNodeId, ')
          ..write('toNodeId: $toNodeId, ')
          ..write('edgeType: $edgeType, ')
          ..write('prereqEdgeId: $prereqEdgeId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $KpGroupsTable extends KpGroups
    with TableInfo<$KpGroupsTable, KpGroupRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $KpGroupsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _versionMeta = const VerificationMeta(
    'version',
  );
  @override
  late final GeneratedColumn<int> version = GeneratedColumn<int>(
    'version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deviceIdMeta = const VerificationMeta(
    'deviceId',
  );
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
    'device_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<DateTime> deletedAt = GeneratedColumn<DateTime>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _canvasIdMeta = const VerificationMeta(
    'canvasId',
  );
  @override
  late final GeneratedColumn<String> canvasId = GeneratedColumn<String>(
    'canvas_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _orderIndexMeta = const VerificationMeta(
    'orderIndex',
  );
  @override
  late final GeneratedColumn<int> orderIndex = GeneratedColumn<int>(
    'order_index',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _foundationalLevelMeta = const VerificationMeta(
    'foundationalLevel',
  );
  @override
  late final GeneratedColumn<int> foundationalLevel = GeneratedColumn<int>(
    'foundational_level',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _membersJsonMeta = const VerificationMeta(
    'membersJson',
  );
  @override
  late final GeneratedColumn<String> membersJson = GeneratedColumn<String>(
    'members_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    version,
    updatedAt,
    deviceId,
    deletedAt,
    canvasId,
    name,
    orderIndex,
    foundationalLevel,
    membersJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'kp_groups';
  @override
  VerificationContext validateIntegrity(
    Insertable<KpGroupRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('version')) {
      context.handle(
        _versionMeta,
        version.isAcceptableOrUnknown(data['version']!, _versionMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('device_id')) {
      context.handle(
        _deviceIdMeta,
        deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_deviceIdMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    if (data.containsKey('canvas_id')) {
      context.handle(
        _canvasIdMeta,
        canvasId.isAcceptableOrUnknown(data['canvas_id']!, _canvasIdMeta),
      );
    } else if (isInserting) {
      context.missing(_canvasIdMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    }
    if (data.containsKey('order_index')) {
      context.handle(
        _orderIndexMeta,
        orderIndex.isAcceptableOrUnknown(data['order_index']!, _orderIndexMeta),
      );
    }
    if (data.containsKey('foundational_level')) {
      context.handle(
        _foundationalLevelMeta,
        foundationalLevel.isAcceptableOrUnknown(
          data['foundational_level']!,
          _foundationalLevelMeta,
        ),
      );
    }
    if (data.containsKey('members_json')) {
      context.handle(
        _membersJsonMeta,
        membersJson.isAcceptableOrUnknown(
          data['members_json']!,
          _membersJsonMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  KpGroupRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return KpGroupRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      version: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}version'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      deviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}device_id'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}deleted_at'],
      ),
      canvasId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}canvas_id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      orderIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}order_index'],
      )!,
      foundationalLevel: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}foundational_level'],
      )!,
      membersJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}members_json'],
      )!,
    );
  }

  @override
  $KpGroupsTable createAlias(String alias) {
    return $KpGroupsTable(attachedDatabase, alias);
  }
}

class KpGroupRow extends DataClass implements Insertable<KpGroupRow> {
  /// ULID 主键。
  final String id;

  /// 本地递增版本号，服务端接管后用于 LWW 冲突判定。
  final int version;
  final DateTime updatedAt;

  /// 产生该次变更的设备，用于同步自回声过滤。
  final String deviceId;

  /// tombstone 软删除：非空即删除，删除靠它传播，不物理删（§11）。
  final DateTime? deletedAt;

  /// 所属知识树（canvases.id）。
  final String canvasId;
  final String name;

  /// 组序（第几组），从 0 开始；越小越基础（越先掌握）。
  final int orderIndex;

  /// 组级基础度（0 = 最基础）。成员未单独标注时用它。
  final int foundationalLevel;

  /// 成员 JSON：`[{"kpId":"...","level":1}]`；`level` 是点级基础度覆盖（缺省用组级）。
  final String membersJson;
  const KpGroupRow({
    required this.id,
    required this.version,
    required this.updatedAt,
    required this.deviceId,
    this.deletedAt,
    required this.canvasId,
    required this.name,
    required this.orderIndex,
    required this.foundationalLevel,
    required this.membersJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['version'] = Variable<int>(version);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    map['device_id'] = Variable<String>(deviceId);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<DateTime>(deletedAt);
    }
    map['canvas_id'] = Variable<String>(canvasId);
    map['name'] = Variable<String>(name);
    map['order_index'] = Variable<int>(orderIndex);
    map['foundational_level'] = Variable<int>(foundationalLevel);
    map['members_json'] = Variable<String>(membersJson);
    return map;
  }

  KpGroupsCompanion toCompanion(bool nullToAbsent) {
    return KpGroupsCompanion(
      id: Value(id),
      version: Value(version),
      updatedAt: Value(updatedAt),
      deviceId: Value(deviceId),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
      canvasId: Value(canvasId),
      name: Value(name),
      orderIndex: Value(orderIndex),
      foundationalLevel: Value(foundationalLevel),
      membersJson: Value(membersJson),
    );
  }

  factory KpGroupRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return KpGroupRow(
      id: serializer.fromJson<String>(json['id']),
      version: serializer.fromJson<int>(json['version']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      deviceId: serializer.fromJson<String>(json['deviceId']),
      deletedAt: serializer.fromJson<DateTime?>(json['deletedAt']),
      canvasId: serializer.fromJson<String>(json['canvasId']),
      name: serializer.fromJson<String>(json['name']),
      orderIndex: serializer.fromJson<int>(json['orderIndex']),
      foundationalLevel: serializer.fromJson<int>(json['foundationalLevel']),
      membersJson: serializer.fromJson<String>(json['membersJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'version': serializer.toJson<int>(version),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'deviceId': serializer.toJson<String>(deviceId),
      'deletedAt': serializer.toJson<DateTime?>(deletedAt),
      'canvasId': serializer.toJson<String>(canvasId),
      'name': serializer.toJson<String>(name),
      'orderIndex': serializer.toJson<int>(orderIndex),
      'foundationalLevel': serializer.toJson<int>(foundationalLevel),
      'membersJson': serializer.toJson<String>(membersJson),
    };
  }

  KpGroupRow copyWith({
    String? id,
    int? version,
    DateTime? updatedAt,
    String? deviceId,
    Value<DateTime?> deletedAt = const Value.absent(),
    String? canvasId,
    String? name,
    int? orderIndex,
    int? foundationalLevel,
    String? membersJson,
  }) => KpGroupRow(
    id: id ?? this.id,
    version: version ?? this.version,
    updatedAt: updatedAt ?? this.updatedAt,
    deviceId: deviceId ?? this.deviceId,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
    canvasId: canvasId ?? this.canvasId,
    name: name ?? this.name,
    orderIndex: orderIndex ?? this.orderIndex,
    foundationalLevel: foundationalLevel ?? this.foundationalLevel,
    membersJson: membersJson ?? this.membersJson,
  );
  KpGroupRow copyWithCompanion(KpGroupsCompanion data) {
    return KpGroupRow(
      id: data.id.present ? data.id.value : this.id,
      version: data.version.present ? data.version.value : this.version,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      canvasId: data.canvasId.present ? data.canvasId.value : this.canvasId,
      name: data.name.present ? data.name.value : this.name,
      orderIndex: data.orderIndex.present
          ? data.orderIndex.value
          : this.orderIndex,
      foundationalLevel: data.foundationalLevel.present
          ? data.foundationalLevel.value
          : this.foundationalLevel,
      membersJson: data.membersJson.present
          ? data.membersJson.value
          : this.membersJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('KpGroupRow(')
          ..write('id: $id, ')
          ..write('version: $version, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deviceId: $deviceId, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('canvasId: $canvasId, ')
          ..write('name: $name, ')
          ..write('orderIndex: $orderIndex, ')
          ..write('foundationalLevel: $foundationalLevel, ')
          ..write('membersJson: $membersJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    version,
    updatedAt,
    deviceId,
    deletedAt,
    canvasId,
    name,
    orderIndex,
    foundationalLevel,
    membersJson,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is KpGroupRow &&
          other.id == this.id &&
          other.version == this.version &&
          other.updatedAt == this.updatedAt &&
          other.deviceId == this.deviceId &&
          other.deletedAt == this.deletedAt &&
          other.canvasId == this.canvasId &&
          other.name == this.name &&
          other.orderIndex == this.orderIndex &&
          other.foundationalLevel == this.foundationalLevel &&
          other.membersJson == this.membersJson);
}

class KpGroupsCompanion extends UpdateCompanion<KpGroupRow> {
  final Value<String> id;
  final Value<int> version;
  final Value<DateTime> updatedAt;
  final Value<String> deviceId;
  final Value<DateTime?> deletedAt;
  final Value<String> canvasId;
  final Value<String> name;
  final Value<int> orderIndex;
  final Value<int> foundationalLevel;
  final Value<String> membersJson;
  final Value<int> rowid;
  const KpGroupsCompanion({
    this.id = const Value.absent(),
    this.version = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.canvasId = const Value.absent(),
    this.name = const Value.absent(),
    this.orderIndex = const Value.absent(),
    this.foundationalLevel = const Value.absent(),
    this.membersJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  KpGroupsCompanion.insert({
    required String id,
    this.version = const Value.absent(),
    required DateTime updatedAt,
    required String deviceId,
    this.deletedAt = const Value.absent(),
    required String canvasId,
    this.name = const Value.absent(),
    this.orderIndex = const Value.absent(),
    this.foundationalLevel = const Value.absent(),
    this.membersJson = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       updatedAt = Value(updatedAt),
       deviceId = Value(deviceId),
       canvasId = Value(canvasId);
  static Insertable<KpGroupRow> custom({
    Expression<String>? id,
    Expression<int>? version,
    Expression<DateTime>? updatedAt,
    Expression<String>? deviceId,
    Expression<DateTime>? deletedAt,
    Expression<String>? canvasId,
    Expression<String>? name,
    Expression<int>? orderIndex,
    Expression<int>? foundationalLevel,
    Expression<String>? membersJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (version != null) 'version': version,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deviceId != null) 'device_id': deviceId,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (canvasId != null) 'canvas_id': canvasId,
      if (name != null) 'name': name,
      if (orderIndex != null) 'order_index': orderIndex,
      if (foundationalLevel != null) 'foundational_level': foundationalLevel,
      if (membersJson != null) 'members_json': membersJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  KpGroupsCompanion copyWith({
    Value<String>? id,
    Value<int>? version,
    Value<DateTime>? updatedAt,
    Value<String>? deviceId,
    Value<DateTime?>? deletedAt,
    Value<String>? canvasId,
    Value<String>? name,
    Value<int>? orderIndex,
    Value<int>? foundationalLevel,
    Value<String>? membersJson,
    Value<int>? rowid,
  }) {
    return KpGroupsCompanion(
      id: id ?? this.id,
      version: version ?? this.version,
      updatedAt: updatedAt ?? this.updatedAt,
      deviceId: deviceId ?? this.deviceId,
      deletedAt: deletedAt ?? this.deletedAt,
      canvasId: canvasId ?? this.canvasId,
      name: name ?? this.name,
      orderIndex: orderIndex ?? this.orderIndex,
      foundationalLevel: foundationalLevel ?? this.foundationalLevel,
      membersJson: membersJson ?? this.membersJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (version.present) {
      map['version'] = Variable<int>(version.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (deviceId.present) {
      map['device_id'] = Variable<String>(deviceId.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<DateTime>(deletedAt.value);
    }
    if (canvasId.present) {
      map['canvas_id'] = Variable<String>(canvasId.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (orderIndex.present) {
      map['order_index'] = Variable<int>(orderIndex.value);
    }
    if (foundationalLevel.present) {
      map['foundational_level'] = Variable<int>(foundationalLevel.value);
    }
    if (membersJson.present) {
      map['members_json'] = Variable<String>(membersJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('KpGroupsCompanion(')
          ..write('id: $id, ')
          ..write('version: $version, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deviceId: $deviceId, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('canvasId: $canvasId, ')
          ..write('name: $name, ')
          ..write('orderIndex: $orderIndex, ')
          ..write('foundationalLevel: $foundationalLevel, ')
          ..write('membersJson: $membersJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $HomeworksTable extends Homeworks
    with TableInfo<$HomeworksTable, HomeworkRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $HomeworksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _versionMeta = const VerificationMeta(
    'version',
  );
  @override
  late final GeneratedColumn<int> version = GeneratedColumn<int>(
    'version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deviceIdMeta = const VerificationMeta(
    'deviceId',
  );
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
    'device_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<DateTime> deletedAt = GeneratedColumn<DateTime>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _canvasIdMeta = const VerificationMeta(
    'canvasId',
  );
  @override
  late final GeneratedColumn<String> canvasId = GeneratedColumn<String>(
    'canvas_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _kpIdsJsonMeta = const VerificationMeta(
    'kpIdsJson',
  );
  @override
  late final GeneratedColumn<String> kpIdsJson = GeneratedColumn<String>(
    'kp_ids_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _itemsJsonMeta = const VerificationMeta(
    'itemsJson',
  );
  @override
  late final GeneratedColumn<String> itemsJson = GeneratedColumn<String>(
    'items_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    version,
    updatedAt,
    deviceId,
    deletedAt,
    canvasId,
    title,
    kpIdsJson,
    itemsJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'homeworks';
  @override
  VerificationContext validateIntegrity(
    Insertable<HomeworkRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('version')) {
      context.handle(
        _versionMeta,
        version.isAcceptableOrUnknown(data['version']!, _versionMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('device_id')) {
      context.handle(
        _deviceIdMeta,
        deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_deviceIdMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    if (data.containsKey('canvas_id')) {
      context.handle(
        _canvasIdMeta,
        canvasId.isAcceptableOrUnknown(data['canvas_id']!, _canvasIdMeta),
      );
    } else if (isInserting) {
      context.missing(_canvasIdMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    }
    if (data.containsKey('kp_ids_json')) {
      context.handle(
        _kpIdsJsonMeta,
        kpIdsJson.isAcceptableOrUnknown(data['kp_ids_json']!, _kpIdsJsonMeta),
      );
    }
    if (data.containsKey('items_json')) {
      context.handle(
        _itemsJsonMeta,
        itemsJson.isAcceptableOrUnknown(data['items_json']!, _itemsJsonMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  HomeworkRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return HomeworkRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      version: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}version'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      deviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}device_id'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}deleted_at'],
      ),
      canvasId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}canvas_id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      kpIdsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kp_ids_json'],
      )!,
      itemsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}items_json'],
      )!,
    );
  }

  @override
  $HomeworksTable createAlias(String alias) {
    return $HomeworksTable(attachedDatabase, alias);
  }
}

class HomeworkRow extends DataClass implements Insertable<HomeworkRow> {
  /// ULID 主键。
  final String id;

  /// 本地递增版本号，服务端接管后用于 LWW 冲突判定。
  final int version;
  final DateTime updatedAt;

  /// 产生该次变更的设备，用于同步自回声过滤。
  final String deviceId;

  /// tombstone 软删除：非空即删除，删除靠它传播，不物理删（§11）。
  final DateTime? deletedAt;

  /// 所属知识树（canvases.id）。
  final String canvasId;

  /// 作业标题。
  final String title;

  /// 布置时选中的薄弱点 id（快照：日后知识点改名不影响历史作业的可读性）。
  final String kpIdsJson;

  /// 题目 JSON：`[{"kpId","kpName","type","question","answer","difficulty"}]`。
  final String itemsJson;
  const HomeworkRow({
    required this.id,
    required this.version,
    required this.updatedAt,
    required this.deviceId,
    this.deletedAt,
    required this.canvasId,
    required this.title,
    required this.kpIdsJson,
    required this.itemsJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['version'] = Variable<int>(version);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    map['device_id'] = Variable<String>(deviceId);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<DateTime>(deletedAt);
    }
    map['canvas_id'] = Variable<String>(canvasId);
    map['title'] = Variable<String>(title);
    map['kp_ids_json'] = Variable<String>(kpIdsJson);
    map['items_json'] = Variable<String>(itemsJson);
    return map;
  }

  HomeworksCompanion toCompanion(bool nullToAbsent) {
    return HomeworksCompanion(
      id: Value(id),
      version: Value(version),
      updatedAt: Value(updatedAt),
      deviceId: Value(deviceId),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
      canvasId: Value(canvasId),
      title: Value(title),
      kpIdsJson: Value(kpIdsJson),
      itemsJson: Value(itemsJson),
    );
  }

  factory HomeworkRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return HomeworkRow(
      id: serializer.fromJson<String>(json['id']),
      version: serializer.fromJson<int>(json['version']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      deviceId: serializer.fromJson<String>(json['deviceId']),
      deletedAt: serializer.fromJson<DateTime?>(json['deletedAt']),
      canvasId: serializer.fromJson<String>(json['canvasId']),
      title: serializer.fromJson<String>(json['title']),
      kpIdsJson: serializer.fromJson<String>(json['kpIdsJson']),
      itemsJson: serializer.fromJson<String>(json['itemsJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'version': serializer.toJson<int>(version),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'deviceId': serializer.toJson<String>(deviceId),
      'deletedAt': serializer.toJson<DateTime?>(deletedAt),
      'canvasId': serializer.toJson<String>(canvasId),
      'title': serializer.toJson<String>(title),
      'kpIdsJson': serializer.toJson<String>(kpIdsJson),
      'itemsJson': serializer.toJson<String>(itemsJson),
    };
  }

  HomeworkRow copyWith({
    String? id,
    int? version,
    DateTime? updatedAt,
    String? deviceId,
    Value<DateTime?> deletedAt = const Value.absent(),
    String? canvasId,
    String? title,
    String? kpIdsJson,
    String? itemsJson,
  }) => HomeworkRow(
    id: id ?? this.id,
    version: version ?? this.version,
    updatedAt: updatedAt ?? this.updatedAt,
    deviceId: deviceId ?? this.deviceId,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
    canvasId: canvasId ?? this.canvasId,
    title: title ?? this.title,
    kpIdsJson: kpIdsJson ?? this.kpIdsJson,
    itemsJson: itemsJson ?? this.itemsJson,
  );
  HomeworkRow copyWithCompanion(HomeworksCompanion data) {
    return HomeworkRow(
      id: data.id.present ? data.id.value : this.id,
      version: data.version.present ? data.version.value : this.version,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      canvasId: data.canvasId.present ? data.canvasId.value : this.canvasId,
      title: data.title.present ? data.title.value : this.title,
      kpIdsJson: data.kpIdsJson.present ? data.kpIdsJson.value : this.kpIdsJson,
      itemsJson: data.itemsJson.present ? data.itemsJson.value : this.itemsJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('HomeworkRow(')
          ..write('id: $id, ')
          ..write('version: $version, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deviceId: $deviceId, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('canvasId: $canvasId, ')
          ..write('title: $title, ')
          ..write('kpIdsJson: $kpIdsJson, ')
          ..write('itemsJson: $itemsJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    version,
    updatedAt,
    deviceId,
    deletedAt,
    canvasId,
    title,
    kpIdsJson,
    itemsJson,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is HomeworkRow &&
          other.id == this.id &&
          other.version == this.version &&
          other.updatedAt == this.updatedAt &&
          other.deviceId == this.deviceId &&
          other.deletedAt == this.deletedAt &&
          other.canvasId == this.canvasId &&
          other.title == this.title &&
          other.kpIdsJson == this.kpIdsJson &&
          other.itemsJson == this.itemsJson);
}

class HomeworksCompanion extends UpdateCompanion<HomeworkRow> {
  final Value<String> id;
  final Value<int> version;
  final Value<DateTime> updatedAt;
  final Value<String> deviceId;
  final Value<DateTime?> deletedAt;
  final Value<String> canvasId;
  final Value<String> title;
  final Value<String> kpIdsJson;
  final Value<String> itemsJson;
  final Value<int> rowid;
  const HomeworksCompanion({
    this.id = const Value.absent(),
    this.version = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.canvasId = const Value.absent(),
    this.title = const Value.absent(),
    this.kpIdsJson = const Value.absent(),
    this.itemsJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  HomeworksCompanion.insert({
    required String id,
    this.version = const Value.absent(),
    required DateTime updatedAt,
    required String deviceId,
    this.deletedAt = const Value.absent(),
    required String canvasId,
    this.title = const Value.absent(),
    this.kpIdsJson = const Value.absent(),
    this.itemsJson = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       updatedAt = Value(updatedAt),
       deviceId = Value(deviceId),
       canvasId = Value(canvasId);
  static Insertable<HomeworkRow> custom({
    Expression<String>? id,
    Expression<int>? version,
    Expression<DateTime>? updatedAt,
    Expression<String>? deviceId,
    Expression<DateTime>? deletedAt,
    Expression<String>? canvasId,
    Expression<String>? title,
    Expression<String>? kpIdsJson,
    Expression<String>? itemsJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (version != null) 'version': version,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deviceId != null) 'device_id': deviceId,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (canvasId != null) 'canvas_id': canvasId,
      if (title != null) 'title': title,
      if (kpIdsJson != null) 'kp_ids_json': kpIdsJson,
      if (itemsJson != null) 'items_json': itemsJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  HomeworksCompanion copyWith({
    Value<String>? id,
    Value<int>? version,
    Value<DateTime>? updatedAt,
    Value<String>? deviceId,
    Value<DateTime?>? deletedAt,
    Value<String>? canvasId,
    Value<String>? title,
    Value<String>? kpIdsJson,
    Value<String>? itemsJson,
    Value<int>? rowid,
  }) {
    return HomeworksCompanion(
      id: id ?? this.id,
      version: version ?? this.version,
      updatedAt: updatedAt ?? this.updatedAt,
      deviceId: deviceId ?? this.deviceId,
      deletedAt: deletedAt ?? this.deletedAt,
      canvasId: canvasId ?? this.canvasId,
      title: title ?? this.title,
      kpIdsJson: kpIdsJson ?? this.kpIdsJson,
      itemsJson: itemsJson ?? this.itemsJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (version.present) {
      map['version'] = Variable<int>(version.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (deviceId.present) {
      map['device_id'] = Variable<String>(deviceId.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<DateTime>(deletedAt.value);
    }
    if (canvasId.present) {
      map['canvas_id'] = Variable<String>(canvasId.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (kpIdsJson.present) {
      map['kp_ids_json'] = Variable<String>(kpIdsJson.value);
    }
    if (itemsJson.present) {
      map['items_json'] = Variable<String>(itemsJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('HomeworksCompanion(')
          ..write('id: $id, ')
          ..write('version: $version, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deviceId: $deviceId, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('canvasId: $canvasId, ')
          ..write('title: $title, ')
          ..write('kpIdsJson: $kpIdsJson, ')
          ..write('itemsJson: $itemsJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AiSessionsTable extends AiSessions
    with TableInfo<$AiSessionsTable, AiSessionRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AiSessionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _versionMeta = const VerificationMeta(
    'version',
  );
  @override
  late final GeneratedColumn<int> version = GeneratedColumn<int>(
    'version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deviceIdMeta = const VerificationMeta(
    'deviceId',
  );
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
    'device_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<DateTime> deletedAt = GeneratedColumn<DateTime>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('chat'),
  );
  static const VerificationMeta _targetRefMeta = const VerificationMeta(
    'targetRef',
  );
  @override
  late final GeneratedColumn<String> targetRef = GeneratedColumn<String>(
    'target_ref',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _kpIdMeta = const VerificationMeta('kpId');
  @override
  late final GeneratedColumn<String> kpId = GeneratedColumn<String>(
    'kp_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _modelIdMeta = const VerificationMeta(
    'modelId',
  );
  @override
  late final GeneratedColumn<String> modelId = GeneratedColumn<String>(
    'model_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _tutorStateMeta = const VerificationMeta(
    'tutorState',
  );
  @override
  late final GeneratedColumn<String> tutorState = GeneratedColumn<String>(
    'tutor_state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('{}'),
  );
  static const VerificationMeta _difficultyMeta = const VerificationMeta(
    'difficulty',
  );
  @override
  late final GeneratedColumn<String> difficulty = GeneratedColumn<String>(
    'difficulty',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    version,
    updatedAt,
    deviceId,
    deletedAt,
    type,
    targetRef,
    title,
    kpId,
    modelId,
    tutorState,
    difficulty,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'ai_sessions';
  @override
  VerificationContext validateIntegrity(
    Insertable<AiSessionRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('version')) {
      context.handle(
        _versionMeta,
        version.isAcceptableOrUnknown(data['version']!, _versionMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('device_id')) {
      context.handle(
        _deviceIdMeta,
        deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_deviceIdMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    }
    if (data.containsKey('target_ref')) {
      context.handle(
        _targetRefMeta,
        targetRef.isAcceptableOrUnknown(data['target_ref']!, _targetRefMeta),
      );
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    }
    if (data.containsKey('kp_id')) {
      context.handle(
        _kpIdMeta,
        kpId.isAcceptableOrUnknown(data['kp_id']!, _kpIdMeta),
      );
    }
    if (data.containsKey('model_id')) {
      context.handle(
        _modelIdMeta,
        modelId.isAcceptableOrUnknown(data['model_id']!, _modelIdMeta),
      );
    }
    if (data.containsKey('tutor_state')) {
      context.handle(
        _tutorStateMeta,
        tutorState.isAcceptableOrUnknown(data['tutor_state']!, _tutorStateMeta),
      );
    }
    if (data.containsKey('difficulty')) {
      context.handle(
        _difficultyMeta,
        difficulty.isAcceptableOrUnknown(data['difficulty']!, _difficultyMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AiSessionRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AiSessionRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      version: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}version'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      deviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}device_id'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}deleted_at'],
      ),
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}type'],
      )!,
      targetRef: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}target_ref'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      kpId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kp_id'],
      ),
      modelId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}model_id'],
      ),
      tutorState: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tutor_state'],
      )!,
      difficulty: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}difficulty'],
      ),
    );
  }

  @override
  $AiSessionsTable createAlias(String alias) {
    return $AiSessionsTable(attachedDatabase, alias);
  }
}

class AiSessionRow extends DataClass implements Insertable<AiSessionRow> {
  /// ULID 主键。
  final String id;

  /// 本地递增版本号，服务端接管后用于 LWW 冲突判定。
  final int version;
  final DateTime updatedAt;

  /// 产生该次变更的设备，用于同步自回声过滤。
  final String deviceId;

  /// tombstone 软删除：非空即删除，删除靠它传播，不物理删（§11）。
  final DateTime? deletedAt;

  /// chat/tutor。
  final String type;
  final String targetRef;
  final String title;

  /// 绑定知识点（老师模式）。
  final String? kpId;
  final String? modelId;

  /// 老师模式状态机（JSON）。
  final String tutorState;
  final String? difficulty;
  const AiSessionRow({
    required this.id,
    required this.version,
    required this.updatedAt,
    required this.deviceId,
    this.deletedAt,
    required this.type,
    required this.targetRef,
    required this.title,
    this.kpId,
    this.modelId,
    required this.tutorState,
    this.difficulty,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['version'] = Variable<int>(version);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    map['device_id'] = Variable<String>(deviceId);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<DateTime>(deletedAt);
    }
    map['type'] = Variable<String>(type);
    map['target_ref'] = Variable<String>(targetRef);
    map['title'] = Variable<String>(title);
    if (!nullToAbsent || kpId != null) {
      map['kp_id'] = Variable<String>(kpId);
    }
    if (!nullToAbsent || modelId != null) {
      map['model_id'] = Variable<String>(modelId);
    }
    map['tutor_state'] = Variable<String>(tutorState);
    if (!nullToAbsent || difficulty != null) {
      map['difficulty'] = Variable<String>(difficulty);
    }
    return map;
  }

  AiSessionsCompanion toCompanion(bool nullToAbsent) {
    return AiSessionsCompanion(
      id: Value(id),
      version: Value(version),
      updatedAt: Value(updatedAt),
      deviceId: Value(deviceId),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
      type: Value(type),
      targetRef: Value(targetRef),
      title: Value(title),
      kpId: kpId == null && nullToAbsent ? const Value.absent() : Value(kpId),
      modelId: modelId == null && nullToAbsent
          ? const Value.absent()
          : Value(modelId),
      tutorState: Value(tutorState),
      difficulty: difficulty == null && nullToAbsent
          ? const Value.absent()
          : Value(difficulty),
    );
  }

  factory AiSessionRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AiSessionRow(
      id: serializer.fromJson<String>(json['id']),
      version: serializer.fromJson<int>(json['version']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      deviceId: serializer.fromJson<String>(json['deviceId']),
      deletedAt: serializer.fromJson<DateTime?>(json['deletedAt']),
      type: serializer.fromJson<String>(json['type']),
      targetRef: serializer.fromJson<String>(json['targetRef']),
      title: serializer.fromJson<String>(json['title']),
      kpId: serializer.fromJson<String?>(json['kpId']),
      modelId: serializer.fromJson<String?>(json['modelId']),
      tutorState: serializer.fromJson<String>(json['tutorState']),
      difficulty: serializer.fromJson<String?>(json['difficulty']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'version': serializer.toJson<int>(version),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'deviceId': serializer.toJson<String>(deviceId),
      'deletedAt': serializer.toJson<DateTime?>(deletedAt),
      'type': serializer.toJson<String>(type),
      'targetRef': serializer.toJson<String>(targetRef),
      'title': serializer.toJson<String>(title),
      'kpId': serializer.toJson<String?>(kpId),
      'modelId': serializer.toJson<String?>(modelId),
      'tutorState': serializer.toJson<String>(tutorState),
      'difficulty': serializer.toJson<String?>(difficulty),
    };
  }

  AiSessionRow copyWith({
    String? id,
    int? version,
    DateTime? updatedAt,
    String? deviceId,
    Value<DateTime?> deletedAt = const Value.absent(),
    String? type,
    String? targetRef,
    String? title,
    Value<String?> kpId = const Value.absent(),
    Value<String?> modelId = const Value.absent(),
    String? tutorState,
    Value<String?> difficulty = const Value.absent(),
  }) => AiSessionRow(
    id: id ?? this.id,
    version: version ?? this.version,
    updatedAt: updatedAt ?? this.updatedAt,
    deviceId: deviceId ?? this.deviceId,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
    type: type ?? this.type,
    targetRef: targetRef ?? this.targetRef,
    title: title ?? this.title,
    kpId: kpId.present ? kpId.value : this.kpId,
    modelId: modelId.present ? modelId.value : this.modelId,
    tutorState: tutorState ?? this.tutorState,
    difficulty: difficulty.present ? difficulty.value : this.difficulty,
  );
  AiSessionRow copyWithCompanion(AiSessionsCompanion data) {
    return AiSessionRow(
      id: data.id.present ? data.id.value : this.id,
      version: data.version.present ? data.version.value : this.version,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      type: data.type.present ? data.type.value : this.type,
      targetRef: data.targetRef.present ? data.targetRef.value : this.targetRef,
      title: data.title.present ? data.title.value : this.title,
      kpId: data.kpId.present ? data.kpId.value : this.kpId,
      modelId: data.modelId.present ? data.modelId.value : this.modelId,
      tutorState: data.tutorState.present
          ? data.tutorState.value
          : this.tutorState,
      difficulty: data.difficulty.present
          ? data.difficulty.value
          : this.difficulty,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AiSessionRow(')
          ..write('id: $id, ')
          ..write('version: $version, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deviceId: $deviceId, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('type: $type, ')
          ..write('targetRef: $targetRef, ')
          ..write('title: $title, ')
          ..write('kpId: $kpId, ')
          ..write('modelId: $modelId, ')
          ..write('tutorState: $tutorState, ')
          ..write('difficulty: $difficulty')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    version,
    updatedAt,
    deviceId,
    deletedAt,
    type,
    targetRef,
    title,
    kpId,
    modelId,
    tutorState,
    difficulty,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AiSessionRow &&
          other.id == this.id &&
          other.version == this.version &&
          other.updatedAt == this.updatedAt &&
          other.deviceId == this.deviceId &&
          other.deletedAt == this.deletedAt &&
          other.type == this.type &&
          other.targetRef == this.targetRef &&
          other.title == this.title &&
          other.kpId == this.kpId &&
          other.modelId == this.modelId &&
          other.tutorState == this.tutorState &&
          other.difficulty == this.difficulty);
}

class AiSessionsCompanion extends UpdateCompanion<AiSessionRow> {
  final Value<String> id;
  final Value<int> version;
  final Value<DateTime> updatedAt;
  final Value<String> deviceId;
  final Value<DateTime?> deletedAt;
  final Value<String> type;
  final Value<String> targetRef;
  final Value<String> title;
  final Value<String?> kpId;
  final Value<String?> modelId;
  final Value<String> tutorState;
  final Value<String?> difficulty;
  final Value<int> rowid;
  const AiSessionsCompanion({
    this.id = const Value.absent(),
    this.version = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.type = const Value.absent(),
    this.targetRef = const Value.absent(),
    this.title = const Value.absent(),
    this.kpId = const Value.absent(),
    this.modelId = const Value.absent(),
    this.tutorState = const Value.absent(),
    this.difficulty = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AiSessionsCompanion.insert({
    required String id,
    this.version = const Value.absent(),
    required DateTime updatedAt,
    required String deviceId,
    this.deletedAt = const Value.absent(),
    this.type = const Value.absent(),
    this.targetRef = const Value.absent(),
    this.title = const Value.absent(),
    this.kpId = const Value.absent(),
    this.modelId = const Value.absent(),
    this.tutorState = const Value.absent(),
    this.difficulty = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       updatedAt = Value(updatedAt),
       deviceId = Value(deviceId);
  static Insertable<AiSessionRow> custom({
    Expression<String>? id,
    Expression<int>? version,
    Expression<DateTime>? updatedAt,
    Expression<String>? deviceId,
    Expression<DateTime>? deletedAt,
    Expression<String>? type,
    Expression<String>? targetRef,
    Expression<String>? title,
    Expression<String>? kpId,
    Expression<String>? modelId,
    Expression<String>? tutorState,
    Expression<String>? difficulty,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (version != null) 'version': version,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deviceId != null) 'device_id': deviceId,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (type != null) 'type': type,
      if (targetRef != null) 'target_ref': targetRef,
      if (title != null) 'title': title,
      if (kpId != null) 'kp_id': kpId,
      if (modelId != null) 'model_id': modelId,
      if (tutorState != null) 'tutor_state': tutorState,
      if (difficulty != null) 'difficulty': difficulty,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AiSessionsCompanion copyWith({
    Value<String>? id,
    Value<int>? version,
    Value<DateTime>? updatedAt,
    Value<String>? deviceId,
    Value<DateTime?>? deletedAt,
    Value<String>? type,
    Value<String>? targetRef,
    Value<String>? title,
    Value<String?>? kpId,
    Value<String?>? modelId,
    Value<String>? tutorState,
    Value<String?>? difficulty,
    Value<int>? rowid,
  }) {
    return AiSessionsCompanion(
      id: id ?? this.id,
      version: version ?? this.version,
      updatedAt: updatedAt ?? this.updatedAt,
      deviceId: deviceId ?? this.deviceId,
      deletedAt: deletedAt ?? this.deletedAt,
      type: type ?? this.type,
      targetRef: targetRef ?? this.targetRef,
      title: title ?? this.title,
      kpId: kpId ?? this.kpId,
      modelId: modelId ?? this.modelId,
      tutorState: tutorState ?? this.tutorState,
      difficulty: difficulty ?? this.difficulty,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (version.present) {
      map['version'] = Variable<int>(version.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (deviceId.present) {
      map['device_id'] = Variable<String>(deviceId.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<DateTime>(deletedAt.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (targetRef.present) {
      map['target_ref'] = Variable<String>(targetRef.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (kpId.present) {
      map['kp_id'] = Variable<String>(kpId.value);
    }
    if (modelId.present) {
      map['model_id'] = Variable<String>(modelId.value);
    }
    if (tutorState.present) {
      map['tutor_state'] = Variable<String>(tutorState.value);
    }
    if (difficulty.present) {
      map['difficulty'] = Variable<String>(difficulty.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AiSessionsCompanion(')
          ..write('id: $id, ')
          ..write('version: $version, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deviceId: $deviceId, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('type: $type, ')
          ..write('targetRef: $targetRef, ')
          ..write('title: $title, ')
          ..write('kpId: $kpId, ')
          ..write('modelId: $modelId, ')
          ..write('tutorState: $tutorState, ')
          ..write('difficulty: $difficulty, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AiMessagesTable extends AiMessages
    with TableInfo<$AiMessagesTable, AiMessageRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AiMessagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _versionMeta = const VerificationMeta(
    'version',
  );
  @override
  late final GeneratedColumn<int> version = GeneratedColumn<int>(
    'version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deviceIdMeta = const VerificationMeta(
    'deviceId',
  );
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
    'device_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<DateTime> deletedAt = GeneratedColumn<DateTime>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sessionIdMeta = const VerificationMeta(
    'sessionId',
  );
  @override
  late final GeneratedColumn<String> sessionId = GeneratedColumn<String>(
    'session_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _roleMeta = const VerificationMeta('role');
  @override
  late final GeneratedColumn<String> role = GeneratedColumn<String>(
    'role',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _contentMdMeta = const VerificationMeta(
    'contentMd',
  );
  @override
  late final GeneratedColumn<String> contentMd = GeneratedColumn<String>(
    'content_md',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _tokensMeta = const VerificationMeta('tokens');
  @override
  late final GeneratedColumn<int> tokens = GeneratedColumn<int>(
    'tokens',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _latencyMsMeta = const VerificationMeta(
    'latencyMs',
  );
  @override
  late final GeneratedColumn<int> latencyMs = GeneratedColumn<int>(
    'latency_ms',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _modelIdMeta = const VerificationMeta(
    'modelId',
  );
  @override
  late final GeneratedColumn<String> modelId = GeneratedColumn<String>(
    'model_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    version,
    updatedAt,
    deviceId,
    deletedAt,
    sessionId,
    role,
    contentMd,
    tokens,
    latencyMs,
    modelId,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'ai_messages';
  @override
  VerificationContext validateIntegrity(
    Insertable<AiMessageRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('version')) {
      context.handle(
        _versionMeta,
        version.isAcceptableOrUnknown(data['version']!, _versionMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('device_id')) {
      context.handle(
        _deviceIdMeta,
        deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_deviceIdMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    if (data.containsKey('session_id')) {
      context.handle(
        _sessionIdMeta,
        sessionId.isAcceptableOrUnknown(data['session_id']!, _sessionIdMeta),
      );
    } else if (isInserting) {
      context.missing(_sessionIdMeta);
    }
    if (data.containsKey('role')) {
      context.handle(
        _roleMeta,
        role.isAcceptableOrUnknown(data['role']!, _roleMeta),
      );
    } else if (isInserting) {
      context.missing(_roleMeta);
    }
    if (data.containsKey('content_md')) {
      context.handle(
        _contentMdMeta,
        contentMd.isAcceptableOrUnknown(data['content_md']!, _contentMdMeta),
      );
    }
    if (data.containsKey('tokens')) {
      context.handle(
        _tokensMeta,
        tokens.isAcceptableOrUnknown(data['tokens']!, _tokensMeta),
      );
    }
    if (data.containsKey('latency_ms')) {
      context.handle(
        _latencyMsMeta,
        latencyMs.isAcceptableOrUnknown(data['latency_ms']!, _latencyMsMeta),
      );
    }
    if (data.containsKey('model_id')) {
      context.handle(
        _modelIdMeta,
        modelId.isAcceptableOrUnknown(data['model_id']!, _modelIdMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AiMessageRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AiMessageRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      version: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}version'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      deviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}device_id'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}deleted_at'],
      ),
      sessionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}session_id'],
      )!,
      role: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}role'],
      )!,
      contentMd: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content_md'],
      )!,
      tokens: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}tokens'],
      ),
      latencyMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}latency_ms'],
      ),
      modelId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}model_id'],
      ),
    );
  }

  @override
  $AiMessagesTable createAlias(String alias) {
    return $AiMessagesTable(attachedDatabase, alias);
  }
}

class AiMessageRow extends DataClass implements Insertable<AiMessageRow> {
  /// ULID 主键。
  final String id;

  /// 本地递增版本号，服务端接管后用于 LWW 冲突判定。
  final int version;
  final DateTime updatedAt;

  /// 产生该次变更的设备，用于同步自回声过滤。
  final String deviceId;

  /// tombstone 软删除：非空即删除，删除靠它传播，不物理删（§11）。
  final DateTime? deletedAt;
  final String sessionId;

  /// user/assistant/system。
  final String role;
  final String contentMd;
  final int? tokens;
  final int? latencyMs;
  final String? modelId;
  const AiMessageRow({
    required this.id,
    required this.version,
    required this.updatedAt,
    required this.deviceId,
    this.deletedAt,
    required this.sessionId,
    required this.role,
    required this.contentMd,
    this.tokens,
    this.latencyMs,
    this.modelId,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['version'] = Variable<int>(version);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    map['device_id'] = Variable<String>(deviceId);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<DateTime>(deletedAt);
    }
    map['session_id'] = Variable<String>(sessionId);
    map['role'] = Variable<String>(role);
    map['content_md'] = Variable<String>(contentMd);
    if (!nullToAbsent || tokens != null) {
      map['tokens'] = Variable<int>(tokens);
    }
    if (!nullToAbsent || latencyMs != null) {
      map['latency_ms'] = Variable<int>(latencyMs);
    }
    if (!nullToAbsent || modelId != null) {
      map['model_id'] = Variable<String>(modelId);
    }
    return map;
  }

  AiMessagesCompanion toCompanion(bool nullToAbsent) {
    return AiMessagesCompanion(
      id: Value(id),
      version: Value(version),
      updatedAt: Value(updatedAt),
      deviceId: Value(deviceId),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
      sessionId: Value(sessionId),
      role: Value(role),
      contentMd: Value(contentMd),
      tokens: tokens == null && nullToAbsent
          ? const Value.absent()
          : Value(tokens),
      latencyMs: latencyMs == null && nullToAbsent
          ? const Value.absent()
          : Value(latencyMs),
      modelId: modelId == null && nullToAbsent
          ? const Value.absent()
          : Value(modelId),
    );
  }

  factory AiMessageRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AiMessageRow(
      id: serializer.fromJson<String>(json['id']),
      version: serializer.fromJson<int>(json['version']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      deviceId: serializer.fromJson<String>(json['deviceId']),
      deletedAt: serializer.fromJson<DateTime?>(json['deletedAt']),
      sessionId: serializer.fromJson<String>(json['sessionId']),
      role: serializer.fromJson<String>(json['role']),
      contentMd: serializer.fromJson<String>(json['contentMd']),
      tokens: serializer.fromJson<int?>(json['tokens']),
      latencyMs: serializer.fromJson<int?>(json['latencyMs']),
      modelId: serializer.fromJson<String?>(json['modelId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'version': serializer.toJson<int>(version),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'deviceId': serializer.toJson<String>(deviceId),
      'deletedAt': serializer.toJson<DateTime?>(deletedAt),
      'sessionId': serializer.toJson<String>(sessionId),
      'role': serializer.toJson<String>(role),
      'contentMd': serializer.toJson<String>(contentMd),
      'tokens': serializer.toJson<int?>(tokens),
      'latencyMs': serializer.toJson<int?>(latencyMs),
      'modelId': serializer.toJson<String?>(modelId),
    };
  }

  AiMessageRow copyWith({
    String? id,
    int? version,
    DateTime? updatedAt,
    String? deviceId,
    Value<DateTime?> deletedAt = const Value.absent(),
    String? sessionId,
    String? role,
    String? contentMd,
    Value<int?> tokens = const Value.absent(),
    Value<int?> latencyMs = const Value.absent(),
    Value<String?> modelId = const Value.absent(),
  }) => AiMessageRow(
    id: id ?? this.id,
    version: version ?? this.version,
    updatedAt: updatedAt ?? this.updatedAt,
    deviceId: deviceId ?? this.deviceId,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
    sessionId: sessionId ?? this.sessionId,
    role: role ?? this.role,
    contentMd: contentMd ?? this.contentMd,
    tokens: tokens.present ? tokens.value : this.tokens,
    latencyMs: latencyMs.present ? latencyMs.value : this.latencyMs,
    modelId: modelId.present ? modelId.value : this.modelId,
  );
  AiMessageRow copyWithCompanion(AiMessagesCompanion data) {
    return AiMessageRow(
      id: data.id.present ? data.id.value : this.id,
      version: data.version.present ? data.version.value : this.version,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      sessionId: data.sessionId.present ? data.sessionId.value : this.sessionId,
      role: data.role.present ? data.role.value : this.role,
      contentMd: data.contentMd.present ? data.contentMd.value : this.contentMd,
      tokens: data.tokens.present ? data.tokens.value : this.tokens,
      latencyMs: data.latencyMs.present ? data.latencyMs.value : this.latencyMs,
      modelId: data.modelId.present ? data.modelId.value : this.modelId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AiMessageRow(')
          ..write('id: $id, ')
          ..write('version: $version, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deviceId: $deviceId, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('sessionId: $sessionId, ')
          ..write('role: $role, ')
          ..write('contentMd: $contentMd, ')
          ..write('tokens: $tokens, ')
          ..write('latencyMs: $latencyMs, ')
          ..write('modelId: $modelId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    version,
    updatedAt,
    deviceId,
    deletedAt,
    sessionId,
    role,
    contentMd,
    tokens,
    latencyMs,
    modelId,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AiMessageRow &&
          other.id == this.id &&
          other.version == this.version &&
          other.updatedAt == this.updatedAt &&
          other.deviceId == this.deviceId &&
          other.deletedAt == this.deletedAt &&
          other.sessionId == this.sessionId &&
          other.role == this.role &&
          other.contentMd == this.contentMd &&
          other.tokens == this.tokens &&
          other.latencyMs == this.latencyMs &&
          other.modelId == this.modelId);
}

class AiMessagesCompanion extends UpdateCompanion<AiMessageRow> {
  final Value<String> id;
  final Value<int> version;
  final Value<DateTime> updatedAt;
  final Value<String> deviceId;
  final Value<DateTime?> deletedAt;
  final Value<String> sessionId;
  final Value<String> role;
  final Value<String> contentMd;
  final Value<int?> tokens;
  final Value<int?> latencyMs;
  final Value<String?> modelId;
  final Value<int> rowid;
  const AiMessagesCompanion({
    this.id = const Value.absent(),
    this.version = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.sessionId = const Value.absent(),
    this.role = const Value.absent(),
    this.contentMd = const Value.absent(),
    this.tokens = const Value.absent(),
    this.latencyMs = const Value.absent(),
    this.modelId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AiMessagesCompanion.insert({
    required String id,
    this.version = const Value.absent(),
    required DateTime updatedAt,
    required String deviceId,
    this.deletedAt = const Value.absent(),
    required String sessionId,
    required String role,
    this.contentMd = const Value.absent(),
    this.tokens = const Value.absent(),
    this.latencyMs = const Value.absent(),
    this.modelId = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       updatedAt = Value(updatedAt),
       deviceId = Value(deviceId),
       sessionId = Value(sessionId),
       role = Value(role);
  static Insertable<AiMessageRow> custom({
    Expression<String>? id,
    Expression<int>? version,
    Expression<DateTime>? updatedAt,
    Expression<String>? deviceId,
    Expression<DateTime>? deletedAt,
    Expression<String>? sessionId,
    Expression<String>? role,
    Expression<String>? contentMd,
    Expression<int>? tokens,
    Expression<int>? latencyMs,
    Expression<String>? modelId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (version != null) 'version': version,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deviceId != null) 'device_id': deviceId,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (sessionId != null) 'session_id': sessionId,
      if (role != null) 'role': role,
      if (contentMd != null) 'content_md': contentMd,
      if (tokens != null) 'tokens': tokens,
      if (latencyMs != null) 'latency_ms': latencyMs,
      if (modelId != null) 'model_id': modelId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AiMessagesCompanion copyWith({
    Value<String>? id,
    Value<int>? version,
    Value<DateTime>? updatedAt,
    Value<String>? deviceId,
    Value<DateTime?>? deletedAt,
    Value<String>? sessionId,
    Value<String>? role,
    Value<String>? contentMd,
    Value<int?>? tokens,
    Value<int?>? latencyMs,
    Value<String?>? modelId,
    Value<int>? rowid,
  }) {
    return AiMessagesCompanion(
      id: id ?? this.id,
      version: version ?? this.version,
      updatedAt: updatedAt ?? this.updatedAt,
      deviceId: deviceId ?? this.deviceId,
      deletedAt: deletedAt ?? this.deletedAt,
      sessionId: sessionId ?? this.sessionId,
      role: role ?? this.role,
      contentMd: contentMd ?? this.contentMd,
      tokens: tokens ?? this.tokens,
      latencyMs: latencyMs ?? this.latencyMs,
      modelId: modelId ?? this.modelId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (version.present) {
      map['version'] = Variable<int>(version.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (deviceId.present) {
      map['device_id'] = Variable<String>(deviceId.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<DateTime>(deletedAt.value);
    }
    if (sessionId.present) {
      map['session_id'] = Variable<String>(sessionId.value);
    }
    if (role.present) {
      map['role'] = Variable<String>(role.value);
    }
    if (contentMd.present) {
      map['content_md'] = Variable<String>(contentMd.value);
    }
    if (tokens.present) {
      map['tokens'] = Variable<int>(tokens.value);
    }
    if (latencyMs.present) {
      map['latency_ms'] = Variable<int>(latencyMs.value);
    }
    if (modelId.present) {
      map['model_id'] = Variable<String>(modelId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AiMessagesCompanion(')
          ..write('id: $id, ')
          ..write('version: $version, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deviceId: $deviceId, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('sessionId: $sessionId, ')
          ..write('role: $role, ')
          ..write('contentMd: $contentMd, ')
          ..write('tokens: $tokens, ')
          ..write('latencyMs: $latencyMs, ')
          ..write('modelId: $modelId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AiProvidersTable extends AiProviders
    with TableInfo<$AiProvidersTable, AiProviderRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AiProvidersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _protocolMeta = const VerificationMeta(
    'protocol',
  );
  @override
  late final GeneratedColumn<String> protocol = GeneratedColumn<String>(
    'protocol',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _baseUrlMeta = const VerificationMeta(
    'baseUrl',
  );
  @override
  late final GeneratedColumn<String> baseUrl = GeneratedColumn<String>(
    'base_url',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _apiKeyRefMeta = const VerificationMeta(
    'apiKeyRef',
  );
  @override
  late final GeneratedColumn<String> apiKeyRef = GeneratedColumn<String>(
    'api_key_ref',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _modelsMeta = const VerificationMeta('models');
  @override
  late final GeneratedColumn<String> models = GeneratedColumn<String>(
    'models',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _isDefaultMeta = const VerificationMeta(
    'isDefault',
  );
  @override
  late final GeneratedColumn<bool> isDefault = GeneratedColumn<bool>(
    'is_default',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_default" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _enabledMeta = const VerificationMeta(
    'enabled',
  );
  @override
  late final GeneratedColumn<bool> enabled = GeneratedColumn<bool>(
    'enabled',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("enabled" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    type,
    protocol,
    baseUrl,
    apiKeyRef,
    models,
    isDefault,
    enabled,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'ai_providers';
  @override
  VerificationContext validateIntegrity(
    Insertable<AiProviderRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    } else if (isInserting) {
      context.missing(_typeMeta);
    }
    if (data.containsKey('protocol')) {
      context.handle(
        _protocolMeta,
        protocol.isAcceptableOrUnknown(data['protocol']!, _protocolMeta),
      );
    } else if (isInserting) {
      context.missing(_protocolMeta);
    }
    if (data.containsKey('base_url')) {
      context.handle(
        _baseUrlMeta,
        baseUrl.isAcceptableOrUnknown(data['base_url']!, _baseUrlMeta),
      );
    }
    if (data.containsKey('api_key_ref')) {
      context.handle(
        _apiKeyRefMeta,
        apiKeyRef.isAcceptableOrUnknown(data['api_key_ref']!, _apiKeyRefMeta),
      );
    }
    if (data.containsKey('models')) {
      context.handle(
        _modelsMeta,
        models.isAcceptableOrUnknown(data['models']!, _modelsMeta),
      );
    }
    if (data.containsKey('is_default')) {
      context.handle(
        _isDefaultMeta,
        isDefault.isAcceptableOrUnknown(data['is_default']!, _isDefaultMeta),
      );
    }
    if (data.containsKey('enabled')) {
      context.handle(
        _enabledMeta,
        enabled.isAcceptableOrUnknown(data['enabled']!, _enabledMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AiProviderRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AiProviderRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}type'],
      )!,
      protocol: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}protocol'],
      )!,
      baseUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}base_url'],
      )!,
      apiKeyRef: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}api_key_ref'],
      )!,
      models: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}models'],
      )!,
      isDefault: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_default'],
      )!,
      enabled: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}enabled'],
      )!,
    );
  }

  @override
  $AiProvidersTable createAlias(String alias) {
    return $AiProvidersTable(attachedDatabase, alias);
  }
}

class AiProviderRow extends DataClass implements Insertable<AiProviderRow> {
  final String id;
  final String name;

  /// 厂商类型：openai/anthropic/ollama/dify/minimax/local。
  /// llm_server 场景复用为 backend 名（auto/ollama/minimax/openai_compat）。
  /// ⚠️ 表结构不可改（Drift 依赖 build_runner 生成 .g.dart）；此处只加注释。
  final String type;

  /// 端点协议：openai / anthropic / dify（已停用）/ llm_server。
  final String protocol;
  final String baseUrl;

  /// 密钥**引用**（指向 SecretStore），绝不明文入表（§5.1）。
  final String apiKeyRef;

  /// 可选模型列表 JSON。
  /// llm_server 场景：JSON 数组，最多 1 个元素 = model 覆盖，`[]` = 用后端默认。
  final String models;
  final bool isDefault;
  final bool enabled;
  const AiProviderRow({
    required this.id,
    required this.name,
    required this.type,
    required this.protocol,
    required this.baseUrl,
    required this.apiKeyRef,
    required this.models,
    required this.isDefault,
    required this.enabled,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    map['type'] = Variable<String>(type);
    map['protocol'] = Variable<String>(protocol);
    map['base_url'] = Variable<String>(baseUrl);
    map['api_key_ref'] = Variable<String>(apiKeyRef);
    map['models'] = Variable<String>(models);
    map['is_default'] = Variable<bool>(isDefault);
    map['enabled'] = Variable<bool>(enabled);
    return map;
  }

  AiProvidersCompanion toCompanion(bool nullToAbsent) {
    return AiProvidersCompanion(
      id: Value(id),
      name: Value(name),
      type: Value(type),
      protocol: Value(protocol),
      baseUrl: Value(baseUrl),
      apiKeyRef: Value(apiKeyRef),
      models: Value(models),
      isDefault: Value(isDefault),
      enabled: Value(enabled),
    );
  }

  factory AiProviderRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AiProviderRow(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      type: serializer.fromJson<String>(json['type']),
      protocol: serializer.fromJson<String>(json['protocol']),
      baseUrl: serializer.fromJson<String>(json['baseUrl']),
      apiKeyRef: serializer.fromJson<String>(json['apiKeyRef']),
      models: serializer.fromJson<String>(json['models']),
      isDefault: serializer.fromJson<bool>(json['isDefault']),
      enabled: serializer.fromJson<bool>(json['enabled']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'type': serializer.toJson<String>(type),
      'protocol': serializer.toJson<String>(protocol),
      'baseUrl': serializer.toJson<String>(baseUrl),
      'apiKeyRef': serializer.toJson<String>(apiKeyRef),
      'models': serializer.toJson<String>(models),
      'isDefault': serializer.toJson<bool>(isDefault),
      'enabled': serializer.toJson<bool>(enabled),
    };
  }

  AiProviderRow copyWith({
    String? id,
    String? name,
    String? type,
    String? protocol,
    String? baseUrl,
    String? apiKeyRef,
    String? models,
    bool? isDefault,
    bool? enabled,
  }) => AiProviderRow(
    id: id ?? this.id,
    name: name ?? this.name,
    type: type ?? this.type,
    protocol: protocol ?? this.protocol,
    baseUrl: baseUrl ?? this.baseUrl,
    apiKeyRef: apiKeyRef ?? this.apiKeyRef,
    models: models ?? this.models,
    isDefault: isDefault ?? this.isDefault,
    enabled: enabled ?? this.enabled,
  );
  AiProviderRow copyWithCompanion(AiProvidersCompanion data) {
    return AiProviderRow(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      type: data.type.present ? data.type.value : this.type,
      protocol: data.protocol.present ? data.protocol.value : this.protocol,
      baseUrl: data.baseUrl.present ? data.baseUrl.value : this.baseUrl,
      apiKeyRef: data.apiKeyRef.present ? data.apiKeyRef.value : this.apiKeyRef,
      models: data.models.present ? data.models.value : this.models,
      isDefault: data.isDefault.present ? data.isDefault.value : this.isDefault,
      enabled: data.enabled.present ? data.enabled.value : this.enabled,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AiProviderRow(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('type: $type, ')
          ..write('protocol: $protocol, ')
          ..write('baseUrl: $baseUrl, ')
          ..write('apiKeyRef: $apiKeyRef, ')
          ..write('models: $models, ')
          ..write('isDefault: $isDefault, ')
          ..write('enabled: $enabled')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    type,
    protocol,
    baseUrl,
    apiKeyRef,
    models,
    isDefault,
    enabled,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AiProviderRow &&
          other.id == this.id &&
          other.name == this.name &&
          other.type == this.type &&
          other.protocol == this.protocol &&
          other.baseUrl == this.baseUrl &&
          other.apiKeyRef == this.apiKeyRef &&
          other.models == this.models &&
          other.isDefault == this.isDefault &&
          other.enabled == this.enabled);
}

class AiProvidersCompanion extends UpdateCompanion<AiProviderRow> {
  final Value<String> id;
  final Value<String> name;
  final Value<String> type;
  final Value<String> protocol;
  final Value<String> baseUrl;
  final Value<String> apiKeyRef;
  final Value<String> models;
  final Value<bool> isDefault;
  final Value<bool> enabled;
  final Value<int> rowid;
  const AiProvidersCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.type = const Value.absent(),
    this.protocol = const Value.absent(),
    this.baseUrl = const Value.absent(),
    this.apiKeyRef = const Value.absent(),
    this.models = const Value.absent(),
    this.isDefault = const Value.absent(),
    this.enabled = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AiProvidersCompanion.insert({
    required String id,
    required String name,
    required String type,
    required String protocol,
    this.baseUrl = const Value.absent(),
    this.apiKeyRef = const Value.absent(),
    this.models = const Value.absent(),
    this.isDefault = const Value.absent(),
    this.enabled = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name),
       type = Value(type),
       protocol = Value(protocol);
  static Insertable<AiProviderRow> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<String>? type,
    Expression<String>? protocol,
    Expression<String>? baseUrl,
    Expression<String>? apiKeyRef,
    Expression<String>? models,
    Expression<bool>? isDefault,
    Expression<bool>? enabled,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (type != null) 'type': type,
      if (protocol != null) 'protocol': protocol,
      if (baseUrl != null) 'base_url': baseUrl,
      if (apiKeyRef != null) 'api_key_ref': apiKeyRef,
      if (models != null) 'models': models,
      if (isDefault != null) 'is_default': isDefault,
      if (enabled != null) 'enabled': enabled,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AiProvidersCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<String>? type,
    Value<String>? protocol,
    Value<String>? baseUrl,
    Value<String>? apiKeyRef,
    Value<String>? models,
    Value<bool>? isDefault,
    Value<bool>? enabled,
    Value<int>? rowid,
  }) {
    return AiProvidersCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      type: type ?? this.type,
      protocol: protocol ?? this.protocol,
      baseUrl: baseUrl ?? this.baseUrl,
      apiKeyRef: apiKeyRef ?? this.apiKeyRef,
      models: models ?? this.models,
      isDefault: isDefault ?? this.isDefault,
      enabled: enabled ?? this.enabled,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (protocol.present) {
      map['protocol'] = Variable<String>(protocol.value);
    }
    if (baseUrl.present) {
      map['base_url'] = Variable<String>(baseUrl.value);
    }
    if (apiKeyRef.present) {
      map['api_key_ref'] = Variable<String>(apiKeyRef.value);
    }
    if (models.present) {
      map['models'] = Variable<String>(models.value);
    }
    if (isDefault.present) {
      map['is_default'] = Variable<bool>(isDefault.value);
    }
    if (enabled.present) {
      map['enabled'] = Variable<bool>(enabled.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AiProvidersCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('type: $type, ')
          ..write('protocol: $protocol, ')
          ..write('baseUrl: $baseUrl, ')
          ..write('apiKeyRef: $apiKeyRef, ')
          ..write('models: $models, ')
          ..write('isDefault: $isDefault, ')
          ..write('enabled: $enabled, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AiTaskRoutesTable extends AiTaskRoutes
    with TableInfo<$AiTaskRoutesTable, AiTaskRouteRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AiTaskRoutesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _aiTaskMeta = const VerificationMeta('aiTask');
  @override
  late final GeneratedColumn<String> aiTask = GeneratedColumn<String>(
    'ai_task',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _providerIdMeta = const VerificationMeta(
    'providerId',
  );
  @override
  late final GeneratedColumn<String> providerId = GeneratedColumn<String>(
    'provider_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _apiKeyRefOverrideMeta = const VerificationMeta(
    'apiKeyRefOverride',
  );
  @override
  late final GeneratedColumn<String> apiKeyRefOverride =
      GeneratedColumn<String>(
        'api_key_ref_override',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _endpointOverrideMeta = const VerificationMeta(
    'endpointOverride',
  );
  @override
  late final GeneratedColumn<String> endpointOverride = GeneratedColumn<String>(
    'endpoint_override',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    aiTask,
    providerId,
    apiKeyRefOverride,
    endpointOverride,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'ai_task_routes';
  @override
  VerificationContext validateIntegrity(
    Insertable<AiTaskRouteRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('ai_task')) {
      context.handle(
        _aiTaskMeta,
        aiTask.isAcceptableOrUnknown(data['ai_task']!, _aiTaskMeta),
      );
    } else if (isInserting) {
      context.missing(_aiTaskMeta);
    }
    if (data.containsKey('provider_id')) {
      context.handle(
        _providerIdMeta,
        providerId.isAcceptableOrUnknown(data['provider_id']!, _providerIdMeta),
      );
    } else if (isInserting) {
      context.missing(_providerIdMeta);
    }
    if (data.containsKey('api_key_ref_override')) {
      context.handle(
        _apiKeyRefOverrideMeta,
        apiKeyRefOverride.isAcceptableOrUnknown(
          data['api_key_ref_override']!,
          _apiKeyRefOverrideMeta,
        ),
      );
    }
    if (data.containsKey('endpoint_override')) {
      context.handle(
        _endpointOverrideMeta,
        endpointOverride.isAcceptableOrUnknown(
          data['endpoint_override']!,
          _endpointOverrideMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AiTaskRouteRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AiTaskRouteRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      aiTask: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}ai_task'],
      )!,
      providerId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}provider_id'],
      )!,
      apiKeyRefOverride: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}api_key_ref_override'],
      ),
      endpointOverride: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}endpoint_override'],
      ),
    );
  }

  @override
  $AiTaskRoutesTable createAlias(String alias) {
    return $AiTaskRoutesTable(attachedDatabase, alias);
  }
}

class AiTaskRouteRow extends DataClass implements Insertable<AiTaskRouteRow> {
  final String id;

  /// 任务枚举名，如 `T1_EXTRACT`。
  final String aiTask;
  final String providerId;
  final String? apiKeyRefOverride;
  final String? endpointOverride;
  const AiTaskRouteRow({
    required this.id,
    required this.aiTask,
    required this.providerId,
    this.apiKeyRefOverride,
    this.endpointOverride,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['ai_task'] = Variable<String>(aiTask);
    map['provider_id'] = Variable<String>(providerId);
    if (!nullToAbsent || apiKeyRefOverride != null) {
      map['api_key_ref_override'] = Variable<String>(apiKeyRefOverride);
    }
    if (!nullToAbsent || endpointOverride != null) {
      map['endpoint_override'] = Variable<String>(endpointOverride);
    }
    return map;
  }

  AiTaskRoutesCompanion toCompanion(bool nullToAbsent) {
    return AiTaskRoutesCompanion(
      id: Value(id),
      aiTask: Value(aiTask),
      providerId: Value(providerId),
      apiKeyRefOverride: apiKeyRefOverride == null && nullToAbsent
          ? const Value.absent()
          : Value(apiKeyRefOverride),
      endpointOverride: endpointOverride == null && nullToAbsent
          ? const Value.absent()
          : Value(endpointOverride),
    );
  }

  factory AiTaskRouteRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AiTaskRouteRow(
      id: serializer.fromJson<String>(json['id']),
      aiTask: serializer.fromJson<String>(json['aiTask']),
      providerId: serializer.fromJson<String>(json['providerId']),
      apiKeyRefOverride: serializer.fromJson<String?>(
        json['apiKeyRefOverride'],
      ),
      endpointOverride: serializer.fromJson<String?>(json['endpointOverride']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'aiTask': serializer.toJson<String>(aiTask),
      'providerId': serializer.toJson<String>(providerId),
      'apiKeyRefOverride': serializer.toJson<String?>(apiKeyRefOverride),
      'endpointOverride': serializer.toJson<String?>(endpointOverride),
    };
  }

  AiTaskRouteRow copyWith({
    String? id,
    String? aiTask,
    String? providerId,
    Value<String?> apiKeyRefOverride = const Value.absent(),
    Value<String?> endpointOverride = const Value.absent(),
  }) => AiTaskRouteRow(
    id: id ?? this.id,
    aiTask: aiTask ?? this.aiTask,
    providerId: providerId ?? this.providerId,
    apiKeyRefOverride: apiKeyRefOverride.present
        ? apiKeyRefOverride.value
        : this.apiKeyRefOverride,
    endpointOverride: endpointOverride.present
        ? endpointOverride.value
        : this.endpointOverride,
  );
  AiTaskRouteRow copyWithCompanion(AiTaskRoutesCompanion data) {
    return AiTaskRouteRow(
      id: data.id.present ? data.id.value : this.id,
      aiTask: data.aiTask.present ? data.aiTask.value : this.aiTask,
      providerId: data.providerId.present
          ? data.providerId.value
          : this.providerId,
      apiKeyRefOverride: data.apiKeyRefOverride.present
          ? data.apiKeyRefOverride.value
          : this.apiKeyRefOverride,
      endpointOverride: data.endpointOverride.present
          ? data.endpointOverride.value
          : this.endpointOverride,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AiTaskRouteRow(')
          ..write('id: $id, ')
          ..write('aiTask: $aiTask, ')
          ..write('providerId: $providerId, ')
          ..write('apiKeyRefOverride: $apiKeyRefOverride, ')
          ..write('endpointOverride: $endpointOverride')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, aiTask, providerId, apiKeyRefOverride, endpointOverride);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AiTaskRouteRow &&
          other.id == this.id &&
          other.aiTask == this.aiTask &&
          other.providerId == this.providerId &&
          other.apiKeyRefOverride == this.apiKeyRefOverride &&
          other.endpointOverride == this.endpointOverride);
}

class AiTaskRoutesCompanion extends UpdateCompanion<AiTaskRouteRow> {
  final Value<String> id;
  final Value<String> aiTask;
  final Value<String> providerId;
  final Value<String?> apiKeyRefOverride;
  final Value<String?> endpointOverride;
  final Value<int> rowid;
  const AiTaskRoutesCompanion({
    this.id = const Value.absent(),
    this.aiTask = const Value.absent(),
    this.providerId = const Value.absent(),
    this.apiKeyRefOverride = const Value.absent(),
    this.endpointOverride = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AiTaskRoutesCompanion.insert({
    required String id,
    required String aiTask,
    required String providerId,
    this.apiKeyRefOverride = const Value.absent(),
    this.endpointOverride = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       aiTask = Value(aiTask),
       providerId = Value(providerId);
  static Insertable<AiTaskRouteRow> custom({
    Expression<String>? id,
    Expression<String>? aiTask,
    Expression<String>? providerId,
    Expression<String>? apiKeyRefOverride,
    Expression<String>? endpointOverride,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (aiTask != null) 'ai_task': aiTask,
      if (providerId != null) 'provider_id': providerId,
      if (apiKeyRefOverride != null) 'api_key_ref_override': apiKeyRefOverride,
      if (endpointOverride != null) 'endpoint_override': endpointOverride,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AiTaskRoutesCompanion copyWith({
    Value<String>? id,
    Value<String>? aiTask,
    Value<String>? providerId,
    Value<String?>? apiKeyRefOverride,
    Value<String?>? endpointOverride,
    Value<int>? rowid,
  }) {
    return AiTaskRoutesCompanion(
      id: id ?? this.id,
      aiTask: aiTask ?? this.aiTask,
      providerId: providerId ?? this.providerId,
      apiKeyRefOverride: apiKeyRefOverride ?? this.apiKeyRefOverride,
      endpointOverride: endpointOverride ?? this.endpointOverride,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (aiTask.present) {
      map['ai_task'] = Variable<String>(aiTask.value);
    }
    if (providerId.present) {
      map['provider_id'] = Variable<String>(providerId.value);
    }
    if (apiKeyRefOverride.present) {
      map['api_key_ref_override'] = Variable<String>(apiKeyRefOverride.value);
    }
    if (endpointOverride.present) {
      map['endpoint_override'] = Variable<String>(endpointOverride.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AiTaskRoutesCompanion(')
          ..write('id: $id, ')
          ..write('aiTask: $aiTask, ')
          ..write('providerId: $providerId, ')
          ..write('apiKeyRefOverride: $apiKeyRefOverride, ')
          ..write('endpointOverride: $endpointOverride, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncOutboxTable extends SyncOutbox
    with TableInfo<$SyncOutboxTable, SyncOutboxRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncOutboxTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _entityTableMeta = const VerificationMeta(
    'entityTable',
  );
  @override
  late final GeneratedColumn<String> entityTable = GeneratedColumn<String>(
    'entity_table',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _entityIdMeta = const VerificationMeta(
    'entityId',
  );
  @override
  late final GeneratedColumn<String> entityId = GeneratedColumn<String>(
    'entity_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _opMeta = const VerificationMeta('op');
  @override
  late final GeneratedColumn<String> op = GeneratedColumn<String>(
    'op',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _payloadJsonMeta = const VerificationMeta(
    'payloadJson',
  );
  @override
  late final GeneratedColumn<String> payloadJson = GeneratedColumn<String>(
    'payload_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deviceIdMeta = const VerificationMeta(
    'deviceId',
  );
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
    'device_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _baseVersionMeta = const VerificationMeta(
    'baseVersion',
  );
  @override
  late final GeneratedColumn<int> baseVersion = GeneratedColumn<int>(
    'base_version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _retryCountMeta = const VerificationMeta(
    'retryCount',
  );
  @override
  late final GeneratedColumn<int> retryCount = GeneratedColumn<int>(
    'retry_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('pending'),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    entityTable,
    entityId,
    op,
    payloadJson,
    deviceId,
    baseVersion,
    retryCount,
    status,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_outbox';
  @override
  VerificationContext validateIntegrity(
    Insertable<SyncOutboxRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('entity_table')) {
      context.handle(
        _entityTableMeta,
        entityTable.isAcceptableOrUnknown(
          data['entity_table']!,
          _entityTableMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_entityTableMeta);
    }
    if (data.containsKey('entity_id')) {
      context.handle(
        _entityIdMeta,
        entityId.isAcceptableOrUnknown(data['entity_id']!, _entityIdMeta),
      );
    } else if (isInserting) {
      context.missing(_entityIdMeta);
    }
    if (data.containsKey('op')) {
      context.handle(_opMeta, op.isAcceptableOrUnknown(data['op']!, _opMeta));
    } else if (isInserting) {
      context.missing(_opMeta);
    }
    if (data.containsKey('payload_json')) {
      context.handle(
        _payloadJsonMeta,
        payloadJson.isAcceptableOrUnknown(
          data['payload_json']!,
          _payloadJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_payloadJsonMeta);
    }
    if (data.containsKey('device_id')) {
      context.handle(
        _deviceIdMeta,
        deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_deviceIdMeta);
    }
    if (data.containsKey('base_version')) {
      context.handle(
        _baseVersionMeta,
        baseVersion.isAcceptableOrUnknown(
          data['base_version']!,
          _baseVersionMeta,
        ),
      );
    }
    if (data.containsKey('retry_count')) {
      context.handle(
        _retryCountMeta,
        retryCount.isAcceptableOrUnknown(data['retry_count']!, _retryCountMeta),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SyncOutboxRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncOutboxRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      entityTable: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}entity_table'],
      )!,
      entityId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}entity_id'],
      )!,
      op: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}op'],
      )!,
      payloadJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload_json'],
      )!,
      deviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}device_id'],
      )!,
      baseVersion: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}base_version'],
      )!,
      retryCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}retry_count'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $SyncOutboxTable createAlias(String alias) {
    return $SyncOutboxTable(attachedDatabase, alias);
  }
}

class SyncOutboxRow extends DataClass implements Insertable<SyncOutboxRow> {
  /// 自增本地序号（不参与同步，故可用自增）。
  final int id;
  final String entityTable;
  final String entityId;

  /// upsert / delete。
  final String op;

  /// 实体最终态 JSON。
  final String payloadJson;
  final String deviceId;
  final int baseVersion;
  final int retryCount;

  /// pending / sending / failed / done。
  final String status;
  final DateTime createdAt;
  const SyncOutboxRow({
    required this.id,
    required this.entityTable,
    required this.entityId,
    required this.op,
    required this.payloadJson,
    required this.deviceId,
    required this.baseVersion,
    required this.retryCount,
    required this.status,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['entity_table'] = Variable<String>(entityTable);
    map['entity_id'] = Variable<String>(entityId);
    map['op'] = Variable<String>(op);
    map['payload_json'] = Variable<String>(payloadJson);
    map['device_id'] = Variable<String>(deviceId);
    map['base_version'] = Variable<int>(baseVersion);
    map['retry_count'] = Variable<int>(retryCount);
    map['status'] = Variable<String>(status);
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  SyncOutboxCompanion toCompanion(bool nullToAbsent) {
    return SyncOutboxCompanion(
      id: Value(id),
      entityTable: Value(entityTable),
      entityId: Value(entityId),
      op: Value(op),
      payloadJson: Value(payloadJson),
      deviceId: Value(deviceId),
      baseVersion: Value(baseVersion),
      retryCount: Value(retryCount),
      status: Value(status),
      createdAt: Value(createdAt),
    );
  }

  factory SyncOutboxRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncOutboxRow(
      id: serializer.fromJson<int>(json['id']),
      entityTable: serializer.fromJson<String>(json['entityTable']),
      entityId: serializer.fromJson<String>(json['entityId']),
      op: serializer.fromJson<String>(json['op']),
      payloadJson: serializer.fromJson<String>(json['payloadJson']),
      deviceId: serializer.fromJson<String>(json['deviceId']),
      baseVersion: serializer.fromJson<int>(json['baseVersion']),
      retryCount: serializer.fromJson<int>(json['retryCount']),
      status: serializer.fromJson<String>(json['status']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'entityTable': serializer.toJson<String>(entityTable),
      'entityId': serializer.toJson<String>(entityId),
      'op': serializer.toJson<String>(op),
      'payloadJson': serializer.toJson<String>(payloadJson),
      'deviceId': serializer.toJson<String>(deviceId),
      'baseVersion': serializer.toJson<int>(baseVersion),
      'retryCount': serializer.toJson<int>(retryCount),
      'status': serializer.toJson<String>(status),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  SyncOutboxRow copyWith({
    int? id,
    String? entityTable,
    String? entityId,
    String? op,
    String? payloadJson,
    String? deviceId,
    int? baseVersion,
    int? retryCount,
    String? status,
    DateTime? createdAt,
  }) => SyncOutboxRow(
    id: id ?? this.id,
    entityTable: entityTable ?? this.entityTable,
    entityId: entityId ?? this.entityId,
    op: op ?? this.op,
    payloadJson: payloadJson ?? this.payloadJson,
    deviceId: deviceId ?? this.deviceId,
    baseVersion: baseVersion ?? this.baseVersion,
    retryCount: retryCount ?? this.retryCount,
    status: status ?? this.status,
    createdAt: createdAt ?? this.createdAt,
  );
  SyncOutboxRow copyWithCompanion(SyncOutboxCompanion data) {
    return SyncOutboxRow(
      id: data.id.present ? data.id.value : this.id,
      entityTable: data.entityTable.present
          ? data.entityTable.value
          : this.entityTable,
      entityId: data.entityId.present ? data.entityId.value : this.entityId,
      op: data.op.present ? data.op.value : this.op,
      payloadJson: data.payloadJson.present
          ? data.payloadJson.value
          : this.payloadJson,
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      baseVersion: data.baseVersion.present
          ? data.baseVersion.value
          : this.baseVersion,
      retryCount: data.retryCount.present
          ? data.retryCount.value
          : this.retryCount,
      status: data.status.present ? data.status.value : this.status,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncOutboxRow(')
          ..write('id: $id, ')
          ..write('entityTable: $entityTable, ')
          ..write('entityId: $entityId, ')
          ..write('op: $op, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('deviceId: $deviceId, ')
          ..write('baseVersion: $baseVersion, ')
          ..write('retryCount: $retryCount, ')
          ..write('status: $status, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    entityTable,
    entityId,
    op,
    payloadJson,
    deviceId,
    baseVersion,
    retryCount,
    status,
    createdAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncOutboxRow &&
          other.id == this.id &&
          other.entityTable == this.entityTable &&
          other.entityId == this.entityId &&
          other.op == this.op &&
          other.payloadJson == this.payloadJson &&
          other.deviceId == this.deviceId &&
          other.baseVersion == this.baseVersion &&
          other.retryCount == this.retryCount &&
          other.status == this.status &&
          other.createdAt == this.createdAt);
}

class SyncOutboxCompanion extends UpdateCompanion<SyncOutboxRow> {
  final Value<int> id;
  final Value<String> entityTable;
  final Value<String> entityId;
  final Value<String> op;
  final Value<String> payloadJson;
  final Value<String> deviceId;
  final Value<int> baseVersion;
  final Value<int> retryCount;
  final Value<String> status;
  final Value<DateTime> createdAt;
  const SyncOutboxCompanion({
    this.id = const Value.absent(),
    this.entityTable = const Value.absent(),
    this.entityId = const Value.absent(),
    this.op = const Value.absent(),
    this.payloadJson = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.baseVersion = const Value.absent(),
    this.retryCount = const Value.absent(),
    this.status = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  SyncOutboxCompanion.insert({
    this.id = const Value.absent(),
    required String entityTable,
    required String entityId,
    required String op,
    required String payloadJson,
    required String deviceId,
    this.baseVersion = const Value.absent(),
    this.retryCount = const Value.absent(),
    this.status = const Value.absent(),
    required DateTime createdAt,
  }) : entityTable = Value(entityTable),
       entityId = Value(entityId),
       op = Value(op),
       payloadJson = Value(payloadJson),
       deviceId = Value(deviceId),
       createdAt = Value(createdAt);
  static Insertable<SyncOutboxRow> custom({
    Expression<int>? id,
    Expression<String>? entityTable,
    Expression<String>? entityId,
    Expression<String>? op,
    Expression<String>? payloadJson,
    Expression<String>? deviceId,
    Expression<int>? baseVersion,
    Expression<int>? retryCount,
    Expression<String>? status,
    Expression<DateTime>? createdAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (entityTable != null) 'entity_table': entityTable,
      if (entityId != null) 'entity_id': entityId,
      if (op != null) 'op': op,
      if (payloadJson != null) 'payload_json': payloadJson,
      if (deviceId != null) 'device_id': deviceId,
      if (baseVersion != null) 'base_version': baseVersion,
      if (retryCount != null) 'retry_count': retryCount,
      if (status != null) 'status': status,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  SyncOutboxCompanion copyWith({
    Value<int>? id,
    Value<String>? entityTable,
    Value<String>? entityId,
    Value<String>? op,
    Value<String>? payloadJson,
    Value<String>? deviceId,
    Value<int>? baseVersion,
    Value<int>? retryCount,
    Value<String>? status,
    Value<DateTime>? createdAt,
  }) {
    return SyncOutboxCompanion(
      id: id ?? this.id,
      entityTable: entityTable ?? this.entityTable,
      entityId: entityId ?? this.entityId,
      op: op ?? this.op,
      payloadJson: payloadJson ?? this.payloadJson,
      deviceId: deviceId ?? this.deviceId,
      baseVersion: baseVersion ?? this.baseVersion,
      retryCount: retryCount ?? this.retryCount,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (entityTable.present) {
      map['entity_table'] = Variable<String>(entityTable.value);
    }
    if (entityId.present) {
      map['entity_id'] = Variable<String>(entityId.value);
    }
    if (op.present) {
      map['op'] = Variable<String>(op.value);
    }
    if (payloadJson.present) {
      map['payload_json'] = Variable<String>(payloadJson.value);
    }
    if (deviceId.present) {
      map['device_id'] = Variable<String>(deviceId.value);
    }
    if (baseVersion.present) {
      map['base_version'] = Variable<int>(baseVersion.value);
    }
    if (retryCount.present) {
      map['retry_count'] = Variable<int>(retryCount.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncOutboxCompanion(')
          ..write('id: $id, ')
          ..write('entityTable: $entityTable, ')
          ..write('entityId: $entityId, ')
          ..write('op: $op, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('deviceId: $deviceId, ')
          ..write('baseVersion: $baseVersion, ')
          ..write('retryCount: $retryCount, ')
          ..write('status: $status, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $NotebooksTable notebooks = $NotebooksTable(this);
  late final $NotesTable notes = $NotesTable(this);
  late final $KnowledgePointsTable knowledgePoints = $KnowledgePointsTable(
    this,
  );
  late final $PrerequisiteEdgesTable prerequisiteEdges =
      $PrerequisiteEdgesTable(this);
  late final $MasteryRecordsTable masteryRecords = $MasteryRecordsTable(this);
  late final $CardsTable cards = $CardsTable(this);
  late final $CanvasesTable canvases = $CanvasesTable(this);
  late final $CanvasNodesTable canvasNodes = $CanvasNodesTable(this);
  late final $CanvasEdgesTable canvasEdges = $CanvasEdgesTable(this);
  late final $KpGroupsTable kpGroups = $KpGroupsTable(this);
  late final $HomeworksTable homeworks = $HomeworksTable(this);
  late final $AiSessionsTable aiSessions = $AiSessionsTable(this);
  late final $AiMessagesTable aiMessages = $AiMessagesTable(this);
  late final $AiProvidersTable aiProviders = $AiProvidersTable(this);
  late final $AiTaskRoutesTable aiTaskRoutes = $AiTaskRoutesTable(this);
  late final $SyncOutboxTable syncOutbox = $SyncOutboxTable(this);
  late final AiTaskRouteDao aiTaskRouteDao = AiTaskRouteDao(
    this as AppDatabase,
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    notebooks,
    notes,
    knowledgePoints,
    prerequisiteEdges,
    masteryRecords,
    cards,
    canvases,
    canvasNodes,
    canvasEdges,
    kpGroups,
    homeworks,
    aiSessions,
    aiMessages,
    aiProviders,
    aiTaskRoutes,
    syncOutbox,
  ];
}

typedef $$NotebooksTableCreateCompanionBuilder = NotebooksCompanion Function({
  required String id,
  Value<int> version,
  required DateTime updatedAt,
  required String deviceId,
  Value<DateTime?> deletedAt,
  required String name,
  Value<String?> parentId,
  Value<int> sortOrder,
  Value<int> rowid,
});
typedef $$NotebooksTableUpdateCompanionBuilder = NotebooksCompanion Function({
  Value<String> id,
  Value<int> version,
  Value<DateTime> updatedAt,
  Value<String> deviceId,
  Value<DateTime?> deletedAt,
  Value<String> name,
  Value<String?> parentId,
  Value<int> sortOrder,
  Value<int> rowid,
});

class $$NotebooksTableFilterComposer
    extends Composer<_$AppDatabase, $NotebooksTable> {
  $$NotebooksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get parentId => $composableBuilder(
    column: $table.parentId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnFilters(column),
  );
}

class $$NotebooksTableOrderingComposer
    extends Composer<_$AppDatabase, $NotebooksTable> {
  $$NotebooksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get parentId => $composableBuilder(
    column: $table.parentId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$NotebooksTableAnnotationComposer
    extends Composer<_$AppDatabase, $NotebooksTable> {
  $$NotebooksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get version =>
      $composableBuilder(column: $table.version, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  GeneratedColumn<DateTime> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get parentId =>
      $composableBuilder(column: $table.parentId, builder: (column) => column);

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);
}

class $$NotebooksTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $NotebooksTable,
          NotebookRow,
          $$NotebooksTableFilterComposer,
          $$NotebooksTableOrderingComposer,
          $$NotebooksTableAnnotationComposer,
          $$NotebooksTableCreateCompanionBuilder,
          $$NotebooksTableUpdateCompanionBuilder,
          (
            NotebookRow,
            BaseReferences<_$AppDatabase, $NotebooksTable, NotebookRow>,
          ),
          NotebookRow,
          PrefetchHooks Function()
        > {
  $$NotebooksTableTableManager(_$AppDatabase db, $NotebooksTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$NotebooksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$NotebooksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$NotebooksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<int> version = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<String> deviceId = const Value.absent(),
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String?> parentId = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => NotebooksCompanion(
                id: id,
                version: version,
                updatedAt: updatedAt,
                deviceId: deviceId,
                deletedAt: deletedAt,
                name: name,
                parentId: parentId,
                sortOrder: sortOrder,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                Value<int> version = const Value.absent(),
                required DateTime updatedAt,
                required String deviceId,
                Value<DateTime?> deletedAt = const Value.absent(),
                required String name,
                Value<String?> parentId = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => NotebooksCompanion.insert(
                id: id,
                version: version,
                updatedAt: updatedAt,
                deviceId: deviceId,
                deletedAt: deletedAt,
                name: name,
                parentId: parentId,
                sortOrder: sortOrder,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$NotebooksTable, NotebookRow>(table),
                  BaseReferences<_$AppDatabase, $NotebooksTable, NotebookRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$NotebooksTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $NotebooksTable,
      NotebookRow,
      $$NotebooksTableFilterComposer,
      $$NotebooksTableOrderingComposer,
      $$NotebooksTableAnnotationComposer,
      $$NotebooksTableCreateCompanionBuilder,
      $$NotebooksTableUpdateCompanionBuilder,
      (
        NotebookRow,
        BaseReferences<_$AppDatabase, $NotebooksTable, NotebookRow>,
      ),
      NotebookRow,
      PrefetchHooks Function()
    >;
typedef $$NotesTableCreateCompanionBuilder = NotesCompanion Function({
  required String id,
  Value<int> version,
  required DateTime updatedAt,
  required String deviceId,
  Value<DateTime?> deletedAt,
  Value<String?> notebookId,
  Value<String> title,
  Value<String> contentMd,
  Value<String> contentHash,
  Value<int> rowid,
});
typedef $$NotesTableUpdateCompanionBuilder = NotesCompanion Function({
  Value<String> id,
  Value<int> version,
  Value<DateTime> updatedAt,
  Value<String> deviceId,
  Value<DateTime?> deletedAt,
  Value<String?> notebookId,
  Value<String> title,
  Value<String> contentMd,
  Value<String> contentHash,
  Value<int> rowid,
});

class $$NotesTableFilterComposer extends Composer<_$AppDatabase, $NotesTable> {
  $$NotesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get notebookId => $composableBuilder(
    column: $table.notebookId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get contentMd => $composableBuilder(
    column: $table.contentMd,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get contentHash => $composableBuilder(
    column: $table.contentHash,
    builder: (column) => ColumnFilters(column),
  );
}

class $$NotesTableOrderingComposer
    extends Composer<_$AppDatabase, $NotesTable> {
  $$NotesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get notebookId => $composableBuilder(
    column: $table.notebookId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get contentMd => $composableBuilder(
    column: $table.contentMd,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get contentHash => $composableBuilder(
    column: $table.contentHash,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$NotesTableAnnotationComposer
    extends Composer<_$AppDatabase, $NotesTable> {
  $$NotesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get version =>
      $composableBuilder(column: $table.version, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  GeneratedColumn<DateTime> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<String> get notebookId => $composableBuilder(
    column: $table.notebookId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get contentMd =>
      $composableBuilder(column: $table.contentMd, builder: (column) => column);

  GeneratedColumn<String> get contentHash => $composableBuilder(
    column: $table.contentHash,
    builder: (column) => column,
  );
}

class $$NotesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $NotesTable,
          NoteRow,
          $$NotesTableFilterComposer,
          $$NotesTableOrderingComposer,
          $$NotesTableAnnotationComposer,
          $$NotesTableCreateCompanionBuilder,
          $$NotesTableUpdateCompanionBuilder,
          (NoteRow, BaseReferences<_$AppDatabase, $NotesTable, NoteRow>),
          NoteRow,
          PrefetchHooks Function()
        > {
  $$NotesTableTableManager(_$AppDatabase db, $NotesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$NotesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$NotesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$NotesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<int> version = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<String> deviceId = const Value.absent(),
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<String?> notebookId = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> contentMd = const Value.absent(),
                Value<String> contentHash = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => NotesCompanion(
                id: id,
                version: version,
                updatedAt: updatedAt,
                deviceId: deviceId,
                deletedAt: deletedAt,
                notebookId: notebookId,
                title: title,
                contentMd: contentMd,
                contentHash: contentHash,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                Value<int> version = const Value.absent(),
                required DateTime updatedAt,
                required String deviceId,
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<String?> notebookId = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> contentMd = const Value.absent(),
                Value<String> contentHash = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => NotesCompanion.insert(
                id: id,
                version: version,
                updatedAt: updatedAt,
                deviceId: deviceId,
                deletedAt: deletedAt,
                notebookId: notebookId,
                title: title,
                contentMd: contentMd,
                contentHash: contentHash,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$NotesTable, NoteRow>(table),
                  BaseReferences<_$AppDatabase, $NotesTable, NoteRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$NotesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $NotesTable,
      NoteRow,
      $$NotesTableFilterComposer,
      $$NotesTableOrderingComposer,
      $$NotesTableAnnotationComposer,
      $$NotesTableCreateCompanionBuilder,
      $$NotesTableUpdateCompanionBuilder,
      (NoteRow, BaseReferences<_$AppDatabase, $NotesTable, NoteRow>),
      NoteRow,
      PrefetchHooks Function()
    >;
typedef $$KnowledgePointsTableCreateCompanionBuilder =
    KnowledgePointsCompanion Function({
      required String id,
      Value<int> version,
      required DateTime updatedAt,
      required String deviceId,
      Value<DateTime?> deletedAt,
      Value<String?> notebookId,
      required String name,
      required String type,
      Value<String> definition,
      required String sourceNoteId,
      required int sourceStart,
      required int sourceEnd,
      required String sourceQuote,
      Value<String> origin,
      Value<double> confidence,
      Value<int> rowid,
    });
typedef $$KnowledgePointsTableUpdateCompanionBuilder =
    KnowledgePointsCompanion Function({
      Value<String> id,
      Value<int> version,
      Value<DateTime> updatedAt,
      Value<String> deviceId,
      Value<DateTime?> deletedAt,
      Value<String?> notebookId,
      Value<String> name,
      Value<String> type,
      Value<String> definition,
      Value<String> sourceNoteId,
      Value<int> sourceStart,
      Value<int> sourceEnd,
      Value<String> sourceQuote,
      Value<String> origin,
      Value<double> confidence,
      Value<int> rowid,
    });

class $$KnowledgePointsTableFilterComposer
    extends Composer<_$AppDatabase, $KnowledgePointsTable> {
  $$KnowledgePointsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get notebookId => $composableBuilder(
    column: $table.notebookId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get definition => $composableBuilder(
    column: $table.definition,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourceNoteId => $composableBuilder(
    column: $table.sourceNoteId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sourceStart => $composableBuilder(
    column: $table.sourceStart,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sourceEnd => $composableBuilder(
    column: $table.sourceEnd,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourceQuote => $composableBuilder(
    column: $table.sourceQuote,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get origin => $composableBuilder(
    column: $table.origin,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get confidence => $composableBuilder(
    column: $table.confidence,
    builder: (column) => ColumnFilters(column),
  );
}

class $$KnowledgePointsTableOrderingComposer
    extends Composer<_$AppDatabase, $KnowledgePointsTable> {
  $$KnowledgePointsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get notebookId => $composableBuilder(
    column: $table.notebookId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get definition => $composableBuilder(
    column: $table.definition,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceNoteId => $composableBuilder(
    column: $table.sourceNoteId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sourceStart => $composableBuilder(
    column: $table.sourceStart,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sourceEnd => $composableBuilder(
    column: $table.sourceEnd,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceQuote => $composableBuilder(
    column: $table.sourceQuote,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get origin => $composableBuilder(
    column: $table.origin,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get confidence => $composableBuilder(
    column: $table.confidence,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$KnowledgePointsTableAnnotationComposer
    extends Composer<_$AppDatabase, $KnowledgePointsTable> {
  $$KnowledgePointsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get version =>
      $composableBuilder(column: $table.version, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  GeneratedColumn<DateTime> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<String> get notebookId => $composableBuilder(
    column: $table.notebookId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<String> get definition => $composableBuilder(
    column: $table.definition,
    builder: (column) => column,
  );

  GeneratedColumn<String> get sourceNoteId => $composableBuilder(
    column: $table.sourceNoteId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get sourceStart => $composableBuilder(
    column: $table.sourceStart,
    builder: (column) => column,
  );

  GeneratedColumn<int> get sourceEnd =>
      $composableBuilder(column: $table.sourceEnd, builder: (column) => column);

  GeneratedColumn<String> get sourceQuote => $composableBuilder(
    column: $table.sourceQuote,
    builder: (column) => column,
  );

  GeneratedColumn<String> get origin =>
      $composableBuilder(column: $table.origin, builder: (column) => column);

  GeneratedColumn<double> get confidence => $composableBuilder(
    column: $table.confidence,
    builder: (column) => column,
  );
}

class $$KnowledgePointsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $KnowledgePointsTable,
          KnowledgePointRow,
          $$KnowledgePointsTableFilterComposer,
          $$KnowledgePointsTableOrderingComposer,
          $$KnowledgePointsTableAnnotationComposer,
          $$KnowledgePointsTableCreateCompanionBuilder,
          $$KnowledgePointsTableUpdateCompanionBuilder,
          (
            KnowledgePointRow,
            BaseReferences<
              _$AppDatabase,
              $KnowledgePointsTable,
              KnowledgePointRow
            >,
          ),
          KnowledgePointRow,
          PrefetchHooks Function()
        > {
  $$KnowledgePointsTableTableManager(
    _$AppDatabase db,
    $KnowledgePointsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$KnowledgePointsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$KnowledgePointsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$KnowledgePointsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<int> version = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<String> deviceId = const Value.absent(),
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<String?> notebookId = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> type = const Value.absent(),
                Value<String> definition = const Value.absent(),
                Value<String> sourceNoteId = const Value.absent(),
                Value<int> sourceStart = const Value.absent(),
                Value<int> sourceEnd = const Value.absent(),
                Value<String> sourceQuote = const Value.absent(),
                Value<String> origin = const Value.absent(),
                Value<double> confidence = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => KnowledgePointsCompanion(
                id: id,
                version: version,
                updatedAt: updatedAt,
                deviceId: deviceId,
                deletedAt: deletedAt,
                notebookId: notebookId,
                name: name,
                type: type,
                definition: definition,
                sourceNoteId: sourceNoteId,
                sourceStart: sourceStart,
                sourceEnd: sourceEnd,
                sourceQuote: sourceQuote,
                origin: origin,
                confidence: confidence,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                Value<int> version = const Value.absent(),
                required DateTime updatedAt,
                required String deviceId,
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<String?> notebookId = const Value.absent(),
                required String name,
                required String type,
                Value<String> definition = const Value.absent(),
                required String sourceNoteId,
                required int sourceStart,
                required int sourceEnd,
                required String sourceQuote,
                Value<String> origin = const Value.absent(),
                Value<double> confidence = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => KnowledgePointsCompanion.insert(
                id: id,
                version: version,
                updatedAt: updatedAt,
                deviceId: deviceId,
                deletedAt: deletedAt,
                notebookId: notebookId,
                name: name,
                type: type,
                definition: definition,
                sourceNoteId: sourceNoteId,
                sourceStart: sourceStart,
                sourceEnd: sourceEnd,
                sourceQuote: sourceQuote,
                origin: origin,
                confidence: confidence,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$KnowledgePointsTable, KnowledgePointRow>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $KnowledgePointsTable,
                    KnowledgePointRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$KnowledgePointsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $KnowledgePointsTable,
      KnowledgePointRow,
      $$KnowledgePointsTableFilterComposer,
      $$KnowledgePointsTableOrderingComposer,
      $$KnowledgePointsTableAnnotationComposer,
      $$KnowledgePointsTableCreateCompanionBuilder,
      $$KnowledgePointsTableUpdateCompanionBuilder,
      (
        KnowledgePointRow,
        BaseReferences<_$AppDatabase, $KnowledgePointsTable, KnowledgePointRow>,
      ),
      KnowledgePointRow,
      PrefetchHooks Function()
    >;
typedef $$PrerequisiteEdgesTableCreateCompanionBuilder =
    PrerequisiteEdgesCompanion Function({
      required String id,
      Value<int> version,
      required DateTime updatedAt,
      required String deviceId,
      Value<DateTime?> deletedAt,
      required String fromKpId,
      required String toKpId,
      Value<String> reason,
      Value<String> origin,
      Value<double> confidence,
      Value<int> rowid,
    });
typedef $$PrerequisiteEdgesTableUpdateCompanionBuilder =
    PrerequisiteEdgesCompanion Function({
      Value<String> id,
      Value<int> version,
      Value<DateTime> updatedAt,
      Value<String> deviceId,
      Value<DateTime?> deletedAt,
      Value<String> fromKpId,
      Value<String> toKpId,
      Value<String> reason,
      Value<String> origin,
      Value<double> confidence,
      Value<int> rowid,
    });

class $$PrerequisiteEdgesTableFilterComposer
    extends Composer<_$AppDatabase, $PrerequisiteEdgesTable> {
  $$PrerequisiteEdgesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fromKpId => $composableBuilder(
    column: $table.fromKpId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get toKpId => $composableBuilder(
    column: $table.toKpId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get reason => $composableBuilder(
    column: $table.reason,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get origin => $composableBuilder(
    column: $table.origin,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get confidence => $composableBuilder(
    column: $table.confidence,
    builder: (column) => ColumnFilters(column),
  );
}

class $$PrerequisiteEdgesTableOrderingComposer
    extends Composer<_$AppDatabase, $PrerequisiteEdgesTable> {
  $$PrerequisiteEdgesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fromKpId => $composableBuilder(
    column: $table.fromKpId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get toKpId => $composableBuilder(
    column: $table.toKpId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get reason => $composableBuilder(
    column: $table.reason,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get origin => $composableBuilder(
    column: $table.origin,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get confidence => $composableBuilder(
    column: $table.confidence,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$PrerequisiteEdgesTableAnnotationComposer
    extends Composer<_$AppDatabase, $PrerequisiteEdgesTable> {
  $$PrerequisiteEdgesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get version =>
      $composableBuilder(column: $table.version, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  GeneratedColumn<DateTime> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<String> get fromKpId =>
      $composableBuilder(column: $table.fromKpId, builder: (column) => column);

  GeneratedColumn<String> get toKpId =>
      $composableBuilder(column: $table.toKpId, builder: (column) => column);

  GeneratedColumn<String> get reason =>
      $composableBuilder(column: $table.reason, builder: (column) => column);

  GeneratedColumn<String> get origin =>
      $composableBuilder(column: $table.origin, builder: (column) => column);

  GeneratedColumn<double> get confidence => $composableBuilder(
    column: $table.confidence,
    builder: (column) => column,
  );
}

class $$PrerequisiteEdgesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $PrerequisiteEdgesTable,
          PrerequisiteEdgeRow,
          $$PrerequisiteEdgesTableFilterComposer,
          $$PrerequisiteEdgesTableOrderingComposer,
          $$PrerequisiteEdgesTableAnnotationComposer,
          $$PrerequisiteEdgesTableCreateCompanionBuilder,
          $$PrerequisiteEdgesTableUpdateCompanionBuilder,
          (
            PrerequisiteEdgeRow,
            BaseReferences<
              _$AppDatabase,
              $PrerequisiteEdgesTable,
              PrerequisiteEdgeRow
            >,
          ),
          PrerequisiteEdgeRow,
          PrefetchHooks Function()
        > {
  $$PrerequisiteEdgesTableTableManager(
    _$AppDatabase db,
    $PrerequisiteEdgesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PrerequisiteEdgesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PrerequisiteEdgesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PrerequisiteEdgesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<int> version = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<String> deviceId = const Value.absent(),
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<String> fromKpId = const Value.absent(),
                Value<String> toKpId = const Value.absent(),
                Value<String> reason = const Value.absent(),
                Value<String> origin = const Value.absent(),
                Value<double> confidence = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PrerequisiteEdgesCompanion(
                id: id,
                version: version,
                updatedAt: updatedAt,
                deviceId: deviceId,
                deletedAt: deletedAt,
                fromKpId: fromKpId,
                toKpId: toKpId,
                reason: reason,
                origin: origin,
                confidence: confidence,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                Value<int> version = const Value.absent(),
                required DateTime updatedAt,
                required String deviceId,
                Value<DateTime?> deletedAt = const Value.absent(),
                required String fromKpId,
                required String toKpId,
                Value<String> reason = const Value.absent(),
                Value<String> origin = const Value.absent(),
                Value<double> confidence = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PrerequisiteEdgesCompanion.insert(
                id: id,
                version: version,
                updatedAt: updatedAt,
                deviceId: deviceId,
                deletedAt: deletedAt,
                fromKpId: fromKpId,
                toKpId: toKpId,
                reason: reason,
                origin: origin,
                confidence: confidence,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$PrerequisiteEdgesTable, PrerequisiteEdgeRow>(
                    table,
                  ),
                  BaseReferences<
                    _$AppDatabase,
                    $PrerequisiteEdgesTable,
                    PrerequisiteEdgeRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$PrerequisiteEdgesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $PrerequisiteEdgesTable,
      PrerequisiteEdgeRow,
      $$PrerequisiteEdgesTableFilterComposer,
      $$PrerequisiteEdgesTableOrderingComposer,
      $$PrerequisiteEdgesTableAnnotationComposer,
      $$PrerequisiteEdgesTableCreateCompanionBuilder,
      $$PrerequisiteEdgesTableUpdateCompanionBuilder,
      (
        PrerequisiteEdgeRow,
        BaseReferences<
          _$AppDatabase,
          $PrerequisiteEdgesTable,
          PrerequisiteEdgeRow
        >,
      ),
      PrerequisiteEdgeRow,
      PrefetchHooks Function()
    >;
typedef $$MasteryRecordsTableCreateCompanionBuilder =
    MasteryRecordsCompanion Function({
      required String id,
      Value<int> version,
      required DateTime updatedAt,
      required String deviceId,
      Value<DateTime?> deletedAt,
      required String kpId,
      required String status,
      Value<String> source,
      Value<int> rowid,
    });
typedef $$MasteryRecordsTableUpdateCompanionBuilder =
    MasteryRecordsCompanion Function({
      Value<String> id,
      Value<int> version,
      Value<DateTime> updatedAt,
      Value<String> deviceId,
      Value<DateTime?> deletedAt,
      Value<String> kpId,
      Value<String> status,
      Value<String> source,
      Value<int> rowid,
    });

class $$MasteryRecordsTableFilterComposer
    extends Composer<_$AppDatabase, $MasteryRecordsTable> {
  $$MasteryRecordsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kpId => $composableBuilder(
    column: $table.kpId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );
}

class $$MasteryRecordsTableOrderingComposer
    extends Composer<_$AppDatabase, $MasteryRecordsTable> {
  $$MasteryRecordsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kpId => $composableBuilder(
    column: $table.kpId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$MasteryRecordsTableAnnotationComposer
    extends Composer<_$AppDatabase, $MasteryRecordsTable> {
  $$MasteryRecordsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get version =>
      $composableBuilder(column: $table.version, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  GeneratedColumn<DateTime> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<String> get kpId =>
      $composableBuilder(column: $table.kpId, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);
}

class $$MasteryRecordsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MasteryRecordsTable,
          MasteryRecordRow,
          $$MasteryRecordsTableFilterComposer,
          $$MasteryRecordsTableOrderingComposer,
          $$MasteryRecordsTableAnnotationComposer,
          $$MasteryRecordsTableCreateCompanionBuilder,
          $$MasteryRecordsTableUpdateCompanionBuilder,
          (
            MasteryRecordRow,
            BaseReferences<
              _$AppDatabase,
              $MasteryRecordsTable,
              MasteryRecordRow
            >,
          ),
          MasteryRecordRow,
          PrefetchHooks Function()
        > {
  $$MasteryRecordsTableTableManager(
    _$AppDatabase db,
    $MasteryRecordsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MasteryRecordsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MasteryRecordsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MasteryRecordsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<int> version = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<String> deviceId = const Value.absent(),
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<String> kpId = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<String> source = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MasteryRecordsCompanion(
                id: id,
                version: version,
                updatedAt: updatedAt,
                deviceId: deviceId,
                deletedAt: deletedAt,
                kpId: kpId,
                status: status,
                source: source,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                Value<int> version = const Value.absent(),
                required DateTime updatedAt,
                required String deviceId,
                Value<DateTime?> deletedAt = const Value.absent(),
                required String kpId,
                required String status,
                Value<String> source = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MasteryRecordsCompanion.insert(
                id: id,
                version: version,
                updatedAt: updatedAt,
                deviceId: deviceId,
                deletedAt: deletedAt,
                kpId: kpId,
                status: status,
                source: source,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$MasteryRecordsTable, MasteryRecordRow>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $MasteryRecordsTable,
                    MasteryRecordRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$MasteryRecordsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MasteryRecordsTable,
      MasteryRecordRow,
      $$MasteryRecordsTableFilterComposer,
      $$MasteryRecordsTableOrderingComposer,
      $$MasteryRecordsTableAnnotationComposer,
      $$MasteryRecordsTableCreateCompanionBuilder,
      $$MasteryRecordsTableUpdateCompanionBuilder,
      (
        MasteryRecordRow,
        BaseReferences<_$AppDatabase, $MasteryRecordsTable, MasteryRecordRow>,
      ),
      MasteryRecordRow,
      PrefetchHooks Function()
    >;
typedef $$CardsTableCreateCompanionBuilder = CardsCompanion Function({
  required String id,
  Value<int> version,
  required DateTime updatedAt,
  required String deviceId,
  Value<DateTime?> deletedAt,
  required String type,
  Value<String> sourceRef,
  Value<String?> parentCardId,
  Value<String?> regeneratedFromId,
  Value<String> contentMd,
  Value<String?> sessionId,
  Value<String?> modelId,
  Value<int> rowid,
});
typedef $$CardsTableUpdateCompanionBuilder = CardsCompanion Function({
  Value<String> id,
  Value<int> version,
  Value<DateTime> updatedAt,
  Value<String> deviceId,
  Value<DateTime?> deletedAt,
  Value<String> type,
  Value<String> sourceRef,
  Value<String?> parentCardId,
  Value<String?> regeneratedFromId,
  Value<String> contentMd,
  Value<String?> sessionId,
  Value<String?> modelId,
  Value<int> rowid,
});

class $$CardsTableFilterComposer extends Composer<_$AppDatabase, $CardsTable> {
  $$CardsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourceRef => $composableBuilder(
    column: $table.sourceRef,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get parentCardId => $composableBuilder(
    column: $table.parentCardId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get regeneratedFromId => $composableBuilder(
    column: $table.regeneratedFromId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get contentMd => $composableBuilder(
    column: $table.contentMd,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sessionId => $composableBuilder(
    column: $table.sessionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get modelId => $composableBuilder(
    column: $table.modelId,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CardsTableOrderingComposer
    extends Composer<_$AppDatabase, $CardsTable> {
  $$CardsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceRef => $composableBuilder(
    column: $table.sourceRef,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get parentCardId => $composableBuilder(
    column: $table.parentCardId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get regeneratedFromId => $composableBuilder(
    column: $table.regeneratedFromId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get contentMd => $composableBuilder(
    column: $table.contentMd,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sessionId => $composableBuilder(
    column: $table.sessionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get modelId => $composableBuilder(
    column: $table.modelId,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CardsTableAnnotationComposer
    extends Composer<_$AppDatabase, $CardsTable> {
  $$CardsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get version =>
      $composableBuilder(column: $table.version, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  GeneratedColumn<DateTime> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<String> get sourceRef =>
      $composableBuilder(column: $table.sourceRef, builder: (column) => column);

  GeneratedColumn<String> get parentCardId => $composableBuilder(
    column: $table.parentCardId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get regeneratedFromId => $composableBuilder(
    column: $table.regeneratedFromId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get contentMd =>
      $composableBuilder(column: $table.contentMd, builder: (column) => column);

  GeneratedColumn<String> get sessionId =>
      $composableBuilder(column: $table.sessionId, builder: (column) => column);

  GeneratedColumn<String> get modelId =>
      $composableBuilder(column: $table.modelId, builder: (column) => column);
}

class $$CardsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CardsTable,
          CardRow,
          $$CardsTableFilterComposer,
          $$CardsTableOrderingComposer,
          $$CardsTableAnnotationComposer,
          $$CardsTableCreateCompanionBuilder,
          $$CardsTableUpdateCompanionBuilder,
          (CardRow, BaseReferences<_$AppDatabase, $CardsTable, CardRow>),
          CardRow,
          PrefetchHooks Function()
        > {
  $$CardsTableTableManager(_$AppDatabase db, $CardsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CardsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CardsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CardsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<int> version = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<String> deviceId = const Value.absent(),
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<String> type = const Value.absent(),
                Value<String> sourceRef = const Value.absent(),
                Value<String?> parentCardId = const Value.absent(),
                Value<String?> regeneratedFromId = const Value.absent(),
                Value<String> contentMd = const Value.absent(),
                Value<String?> sessionId = const Value.absent(),
                Value<String?> modelId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CardsCompanion(
                id: id,
                version: version,
                updatedAt: updatedAt,
                deviceId: deviceId,
                deletedAt: deletedAt,
                type: type,
                sourceRef: sourceRef,
                parentCardId: parentCardId,
                regeneratedFromId: regeneratedFromId,
                contentMd: contentMd,
                sessionId: sessionId,
                modelId: modelId,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                Value<int> version = const Value.absent(),
                required DateTime updatedAt,
                required String deviceId,
                Value<DateTime?> deletedAt = const Value.absent(),
                required String type,
                Value<String> sourceRef = const Value.absent(),
                Value<String?> parentCardId = const Value.absent(),
                Value<String?> regeneratedFromId = const Value.absent(),
                Value<String> contentMd = const Value.absent(),
                Value<String?> sessionId = const Value.absent(),
                Value<String?> modelId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CardsCompanion.insert(
                id: id,
                version: version,
                updatedAt: updatedAt,
                deviceId: deviceId,
                deletedAt: deletedAt,
                type: type,
                sourceRef: sourceRef,
                parentCardId: parentCardId,
                regeneratedFromId: regeneratedFromId,
                contentMd: contentMd,
                sessionId: sessionId,
                modelId: modelId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$CardsTable, CardRow>(table),
                  BaseReferences<_$AppDatabase, $CardsTable, CardRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CardsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CardsTable,
      CardRow,
      $$CardsTableFilterComposer,
      $$CardsTableOrderingComposer,
      $$CardsTableAnnotationComposer,
      $$CardsTableCreateCompanionBuilder,
      $$CardsTableUpdateCompanionBuilder,
      (CardRow, BaseReferences<_$AppDatabase, $CardsTable, CardRow>),
      CardRow,
      PrefetchHooks Function()
    >;
typedef $$CanvasesTableCreateCompanionBuilder = CanvasesCompanion Function({
  required String id,
  Value<int> version,
  required DateTime updatedAt,
  required String deviceId,
  Value<DateTime?> deletedAt,
  Value<String?> notebookId,
  Value<String> name,
  Value<String> viewport,
  Value<int> rowid,
});
typedef $$CanvasesTableUpdateCompanionBuilder = CanvasesCompanion Function({
  Value<String> id,
  Value<int> version,
  Value<DateTime> updatedAt,
  Value<String> deviceId,
  Value<DateTime?> deletedAt,
  Value<String?> notebookId,
  Value<String> name,
  Value<String> viewport,
  Value<int> rowid,
});

class $$CanvasesTableFilterComposer
    extends Composer<_$AppDatabase, $CanvasesTable> {
  $$CanvasesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get notebookId => $composableBuilder(
    column: $table.notebookId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get viewport => $composableBuilder(
    column: $table.viewport,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CanvasesTableOrderingComposer
    extends Composer<_$AppDatabase, $CanvasesTable> {
  $$CanvasesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get notebookId => $composableBuilder(
    column: $table.notebookId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get viewport => $composableBuilder(
    column: $table.viewport,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CanvasesTableAnnotationComposer
    extends Composer<_$AppDatabase, $CanvasesTable> {
  $$CanvasesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get version =>
      $composableBuilder(column: $table.version, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  GeneratedColumn<DateTime> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<String> get notebookId => $composableBuilder(
    column: $table.notebookId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get viewport =>
      $composableBuilder(column: $table.viewport, builder: (column) => column);
}

class $$CanvasesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CanvasesTable,
          CanvasRow,
          $$CanvasesTableFilterComposer,
          $$CanvasesTableOrderingComposer,
          $$CanvasesTableAnnotationComposer,
          $$CanvasesTableCreateCompanionBuilder,
          $$CanvasesTableUpdateCompanionBuilder,
          (CanvasRow, BaseReferences<_$AppDatabase, $CanvasesTable, CanvasRow>),
          CanvasRow,
          PrefetchHooks Function()
        > {
  $$CanvasesTableTableManager(_$AppDatabase db, $CanvasesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CanvasesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CanvasesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CanvasesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<int> version = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<String> deviceId = const Value.absent(),
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<String?> notebookId = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> viewport = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CanvasesCompanion(
                id: id,
                version: version,
                updatedAt: updatedAt,
                deviceId: deviceId,
                deletedAt: deletedAt,
                notebookId: notebookId,
                name: name,
                viewport: viewport,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                Value<int> version = const Value.absent(),
                required DateTime updatedAt,
                required String deviceId,
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<String?> notebookId = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> viewport = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CanvasesCompanion.insert(
                id: id,
                version: version,
                updatedAt: updatedAt,
                deviceId: deviceId,
                deletedAt: deletedAt,
                notebookId: notebookId,
                name: name,
                viewport: viewport,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$CanvasesTable, CanvasRow>(table),
                  BaseReferences<_$AppDatabase, $CanvasesTable, CanvasRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CanvasesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CanvasesTable,
      CanvasRow,
      $$CanvasesTableFilterComposer,
      $$CanvasesTableOrderingComposer,
      $$CanvasesTableAnnotationComposer,
      $$CanvasesTableCreateCompanionBuilder,
      $$CanvasesTableUpdateCompanionBuilder,
      (CanvasRow, BaseReferences<_$AppDatabase, $CanvasesTable, CanvasRow>),
      CanvasRow,
      PrefetchHooks Function()
    >;
typedef $$CanvasNodesTableCreateCompanionBuilder =
    CanvasNodesCompanion Function({
      required String id,
      Value<int> version,
      required DateTime updatedAt,
      required String deviceId,
      Value<DateTime?> deletedAt,
      required String canvasId,
      required String targetType,
      required String targetId,
      Value<double> x,
      Value<double> y,
      Value<double> w,
      Value<double> h,
      Value<int> z,
      Value<bool> collapsed,
      Value<bool> pinned,
      Value<int> rowid,
    });
typedef $$CanvasNodesTableUpdateCompanionBuilder =
    CanvasNodesCompanion Function({
      Value<String> id,
      Value<int> version,
      Value<DateTime> updatedAt,
      Value<String> deviceId,
      Value<DateTime?> deletedAt,
      Value<String> canvasId,
      Value<String> targetType,
      Value<String> targetId,
      Value<double> x,
      Value<double> y,
      Value<double> w,
      Value<double> h,
      Value<int> z,
      Value<bool> collapsed,
      Value<bool> pinned,
      Value<int> rowid,
    });

class $$CanvasNodesTableFilterComposer
    extends Composer<_$AppDatabase, $CanvasNodesTable> {
  $$CanvasNodesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get canvasId => $composableBuilder(
    column: $table.canvasId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get targetType => $composableBuilder(
    column: $table.targetType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get targetId => $composableBuilder(
    column: $table.targetId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get x => $composableBuilder(
    column: $table.x,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get y => $composableBuilder(
    column: $table.y,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get w => $composableBuilder(
    column: $table.w,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get h => $composableBuilder(
    column: $table.h,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get z => $composableBuilder(
    column: $table.z,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get collapsed => $composableBuilder(
    column: $table.collapsed,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get pinned => $composableBuilder(
    column: $table.pinned,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CanvasNodesTableOrderingComposer
    extends Composer<_$AppDatabase, $CanvasNodesTable> {
  $$CanvasNodesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get canvasId => $composableBuilder(
    column: $table.canvasId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get targetType => $composableBuilder(
    column: $table.targetType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get targetId => $composableBuilder(
    column: $table.targetId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get x => $composableBuilder(
    column: $table.x,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get y => $composableBuilder(
    column: $table.y,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get w => $composableBuilder(
    column: $table.w,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get h => $composableBuilder(
    column: $table.h,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get z => $composableBuilder(
    column: $table.z,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get collapsed => $composableBuilder(
    column: $table.collapsed,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get pinned => $composableBuilder(
    column: $table.pinned,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CanvasNodesTableAnnotationComposer
    extends Composer<_$AppDatabase, $CanvasNodesTable> {
  $$CanvasNodesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get version =>
      $composableBuilder(column: $table.version, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  GeneratedColumn<DateTime> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<String> get canvasId =>
      $composableBuilder(column: $table.canvasId, builder: (column) => column);

  GeneratedColumn<String> get targetType => $composableBuilder(
    column: $table.targetType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get targetId =>
      $composableBuilder(column: $table.targetId, builder: (column) => column);

  GeneratedColumn<double> get x =>
      $composableBuilder(column: $table.x, builder: (column) => column);

  GeneratedColumn<double> get y =>
      $composableBuilder(column: $table.y, builder: (column) => column);

  GeneratedColumn<double> get w =>
      $composableBuilder(column: $table.w, builder: (column) => column);

  GeneratedColumn<double> get h =>
      $composableBuilder(column: $table.h, builder: (column) => column);

  GeneratedColumn<int> get z =>
      $composableBuilder(column: $table.z, builder: (column) => column);

  GeneratedColumn<bool> get collapsed =>
      $composableBuilder(column: $table.collapsed, builder: (column) => column);

  GeneratedColumn<bool> get pinned =>
      $composableBuilder(column: $table.pinned, builder: (column) => column);
}

class $$CanvasNodesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CanvasNodesTable,
          CanvasNodeRow,
          $$CanvasNodesTableFilterComposer,
          $$CanvasNodesTableOrderingComposer,
          $$CanvasNodesTableAnnotationComposer,
          $$CanvasNodesTableCreateCompanionBuilder,
          $$CanvasNodesTableUpdateCompanionBuilder,
          (
            CanvasNodeRow,
            BaseReferences<_$AppDatabase, $CanvasNodesTable, CanvasNodeRow>,
          ),
          CanvasNodeRow,
          PrefetchHooks Function()
        > {
  $$CanvasNodesTableTableManager(_$AppDatabase db, $CanvasNodesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CanvasNodesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CanvasNodesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CanvasNodesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<int> version = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<String> deviceId = const Value.absent(),
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<String> canvasId = const Value.absent(),
                Value<String> targetType = const Value.absent(),
                Value<String> targetId = const Value.absent(),
                Value<double> x = const Value.absent(),
                Value<double> y = const Value.absent(),
                Value<double> w = const Value.absent(),
                Value<double> h = const Value.absent(),
                Value<int> z = const Value.absent(),
                Value<bool> collapsed = const Value.absent(),
                Value<bool> pinned = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CanvasNodesCompanion(
                id: id,
                version: version,
                updatedAt: updatedAt,
                deviceId: deviceId,
                deletedAt: deletedAt,
                canvasId: canvasId,
                targetType: targetType,
                targetId: targetId,
                x: x,
                y: y,
                w: w,
                h: h,
                z: z,
                collapsed: collapsed,
                pinned: pinned,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                Value<int> version = const Value.absent(),
                required DateTime updatedAt,
                required String deviceId,
                Value<DateTime?> deletedAt = const Value.absent(),
                required String canvasId,
                required String targetType,
                required String targetId,
                Value<double> x = const Value.absent(),
                Value<double> y = const Value.absent(),
                Value<double> w = const Value.absent(),
                Value<double> h = const Value.absent(),
                Value<int> z = const Value.absent(),
                Value<bool> collapsed = const Value.absent(),
                Value<bool> pinned = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CanvasNodesCompanion.insert(
                id: id,
                version: version,
                updatedAt: updatedAt,
                deviceId: deviceId,
                deletedAt: deletedAt,
                canvasId: canvasId,
                targetType: targetType,
                targetId: targetId,
                x: x,
                y: y,
                w: w,
                h: h,
                z: z,
                collapsed: collapsed,
                pinned: pinned,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$CanvasNodesTable, CanvasNodeRow>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $CanvasNodesTable,
                    CanvasNodeRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CanvasNodesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CanvasNodesTable,
      CanvasNodeRow,
      $$CanvasNodesTableFilterComposer,
      $$CanvasNodesTableOrderingComposer,
      $$CanvasNodesTableAnnotationComposer,
      $$CanvasNodesTableCreateCompanionBuilder,
      $$CanvasNodesTableUpdateCompanionBuilder,
      (
        CanvasNodeRow,
        BaseReferences<_$AppDatabase, $CanvasNodesTable, CanvasNodeRow>,
      ),
      CanvasNodeRow,
      PrefetchHooks Function()
    >;
typedef $$CanvasEdgesTableCreateCompanionBuilder =
    CanvasEdgesCompanion Function({
      required String id,
      Value<int> version,
      required DateTime updatedAt,
      required String deviceId,
      Value<DateTime?> deletedAt,
      required String canvasId,
      required String fromNodeId,
      required String toNodeId,
      Value<String> edgeType,
      Value<String?> prereqEdgeId,
      Value<int> rowid,
    });
typedef $$CanvasEdgesTableUpdateCompanionBuilder =
    CanvasEdgesCompanion Function({
      Value<String> id,
      Value<int> version,
      Value<DateTime> updatedAt,
      Value<String> deviceId,
      Value<DateTime?> deletedAt,
      Value<String> canvasId,
      Value<String> fromNodeId,
      Value<String> toNodeId,
      Value<String> edgeType,
      Value<String?> prereqEdgeId,
      Value<int> rowid,
    });

class $$CanvasEdgesTableFilterComposer
    extends Composer<_$AppDatabase, $CanvasEdgesTable> {
  $$CanvasEdgesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get canvasId => $composableBuilder(
    column: $table.canvasId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fromNodeId => $composableBuilder(
    column: $table.fromNodeId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get toNodeId => $composableBuilder(
    column: $table.toNodeId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get edgeType => $composableBuilder(
    column: $table.edgeType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get prereqEdgeId => $composableBuilder(
    column: $table.prereqEdgeId,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CanvasEdgesTableOrderingComposer
    extends Composer<_$AppDatabase, $CanvasEdgesTable> {
  $$CanvasEdgesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get canvasId => $composableBuilder(
    column: $table.canvasId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fromNodeId => $composableBuilder(
    column: $table.fromNodeId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get toNodeId => $composableBuilder(
    column: $table.toNodeId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get edgeType => $composableBuilder(
    column: $table.edgeType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get prereqEdgeId => $composableBuilder(
    column: $table.prereqEdgeId,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CanvasEdgesTableAnnotationComposer
    extends Composer<_$AppDatabase, $CanvasEdgesTable> {
  $$CanvasEdgesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get version =>
      $composableBuilder(column: $table.version, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  GeneratedColumn<DateTime> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<String> get canvasId =>
      $composableBuilder(column: $table.canvasId, builder: (column) => column);

  GeneratedColumn<String> get fromNodeId => $composableBuilder(
    column: $table.fromNodeId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get toNodeId =>
      $composableBuilder(column: $table.toNodeId, builder: (column) => column);

  GeneratedColumn<String> get edgeType =>
      $composableBuilder(column: $table.edgeType, builder: (column) => column);

  GeneratedColumn<String> get prereqEdgeId => $composableBuilder(
    column: $table.prereqEdgeId,
    builder: (column) => column,
  );
}

class $$CanvasEdgesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CanvasEdgesTable,
          CanvasEdgeRow,
          $$CanvasEdgesTableFilterComposer,
          $$CanvasEdgesTableOrderingComposer,
          $$CanvasEdgesTableAnnotationComposer,
          $$CanvasEdgesTableCreateCompanionBuilder,
          $$CanvasEdgesTableUpdateCompanionBuilder,
          (
            CanvasEdgeRow,
            BaseReferences<_$AppDatabase, $CanvasEdgesTable, CanvasEdgeRow>,
          ),
          CanvasEdgeRow,
          PrefetchHooks Function()
        > {
  $$CanvasEdgesTableTableManager(_$AppDatabase db, $CanvasEdgesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CanvasEdgesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CanvasEdgesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CanvasEdgesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<int> version = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<String> deviceId = const Value.absent(),
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<String> canvasId = const Value.absent(),
                Value<String> fromNodeId = const Value.absent(),
                Value<String> toNodeId = const Value.absent(),
                Value<String> edgeType = const Value.absent(),
                Value<String?> prereqEdgeId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CanvasEdgesCompanion(
                id: id,
                version: version,
                updatedAt: updatedAt,
                deviceId: deviceId,
                deletedAt: deletedAt,
                canvasId: canvasId,
                fromNodeId: fromNodeId,
                toNodeId: toNodeId,
                edgeType: edgeType,
                prereqEdgeId: prereqEdgeId,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                Value<int> version = const Value.absent(),
                required DateTime updatedAt,
                required String deviceId,
                Value<DateTime?> deletedAt = const Value.absent(),
                required String canvasId,
                required String fromNodeId,
                required String toNodeId,
                Value<String> edgeType = const Value.absent(),
                Value<String?> prereqEdgeId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CanvasEdgesCompanion.insert(
                id: id,
                version: version,
                updatedAt: updatedAt,
                deviceId: deviceId,
                deletedAt: deletedAt,
                canvasId: canvasId,
                fromNodeId: fromNodeId,
                toNodeId: toNodeId,
                edgeType: edgeType,
                prereqEdgeId: prereqEdgeId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$CanvasEdgesTable, CanvasEdgeRow>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $CanvasEdgesTable,
                    CanvasEdgeRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CanvasEdgesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CanvasEdgesTable,
      CanvasEdgeRow,
      $$CanvasEdgesTableFilterComposer,
      $$CanvasEdgesTableOrderingComposer,
      $$CanvasEdgesTableAnnotationComposer,
      $$CanvasEdgesTableCreateCompanionBuilder,
      $$CanvasEdgesTableUpdateCompanionBuilder,
      (
        CanvasEdgeRow,
        BaseReferences<_$AppDatabase, $CanvasEdgesTable, CanvasEdgeRow>,
      ),
      CanvasEdgeRow,
      PrefetchHooks Function()
    >;
typedef $$KpGroupsTableCreateCompanionBuilder = KpGroupsCompanion Function({
  required String id,
  Value<int> version,
  required DateTime updatedAt,
  required String deviceId,
  Value<DateTime?> deletedAt,
  required String canvasId,
  Value<String> name,
  Value<int> orderIndex,
  Value<int> foundationalLevel,
  Value<String> membersJson,
  Value<int> rowid,
});
typedef $$KpGroupsTableUpdateCompanionBuilder = KpGroupsCompanion Function({
  Value<String> id,
  Value<int> version,
  Value<DateTime> updatedAt,
  Value<String> deviceId,
  Value<DateTime?> deletedAt,
  Value<String> canvasId,
  Value<String> name,
  Value<int> orderIndex,
  Value<int> foundationalLevel,
  Value<String> membersJson,
  Value<int> rowid,
});

class $$KpGroupsTableFilterComposer
    extends Composer<_$AppDatabase, $KpGroupsTable> {
  $$KpGroupsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get canvasId => $composableBuilder(
    column: $table.canvasId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get orderIndex => $composableBuilder(
    column: $table.orderIndex,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get foundationalLevel => $composableBuilder(
    column: $table.foundationalLevel,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get membersJson => $composableBuilder(
    column: $table.membersJson,
    builder: (column) => ColumnFilters(column),
  );
}

class $$KpGroupsTableOrderingComposer
    extends Composer<_$AppDatabase, $KpGroupsTable> {
  $$KpGroupsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get canvasId => $composableBuilder(
    column: $table.canvasId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get orderIndex => $composableBuilder(
    column: $table.orderIndex,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get foundationalLevel => $composableBuilder(
    column: $table.foundationalLevel,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get membersJson => $composableBuilder(
    column: $table.membersJson,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$KpGroupsTableAnnotationComposer
    extends Composer<_$AppDatabase, $KpGroupsTable> {
  $$KpGroupsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get version =>
      $composableBuilder(column: $table.version, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  GeneratedColumn<DateTime> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<String> get canvasId =>
      $composableBuilder(column: $table.canvasId, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get orderIndex => $composableBuilder(
    column: $table.orderIndex,
    builder: (column) => column,
  );

  GeneratedColumn<int> get foundationalLevel => $composableBuilder(
    column: $table.foundationalLevel,
    builder: (column) => column,
  );

  GeneratedColumn<String> get membersJson => $composableBuilder(
    column: $table.membersJson,
    builder: (column) => column,
  );
}

class $$KpGroupsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $KpGroupsTable,
          KpGroupRow,
          $$KpGroupsTableFilterComposer,
          $$KpGroupsTableOrderingComposer,
          $$KpGroupsTableAnnotationComposer,
          $$KpGroupsTableCreateCompanionBuilder,
          $$KpGroupsTableUpdateCompanionBuilder,
          (
            KpGroupRow,
            BaseReferences<_$AppDatabase, $KpGroupsTable, KpGroupRow>,
          ),
          KpGroupRow,
          PrefetchHooks Function()
        > {
  $$KpGroupsTableTableManager(_$AppDatabase db, $KpGroupsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$KpGroupsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$KpGroupsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$KpGroupsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<int> version = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<String> deviceId = const Value.absent(),
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<String> canvasId = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<int> orderIndex = const Value.absent(),
                Value<int> foundationalLevel = const Value.absent(),
                Value<String> membersJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => KpGroupsCompanion(
                id: id,
                version: version,
                updatedAt: updatedAt,
                deviceId: deviceId,
                deletedAt: deletedAt,
                canvasId: canvasId,
                name: name,
                orderIndex: orderIndex,
                foundationalLevel: foundationalLevel,
                membersJson: membersJson,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                Value<int> version = const Value.absent(),
                required DateTime updatedAt,
                required String deviceId,
                Value<DateTime?> deletedAt = const Value.absent(),
                required String canvasId,
                Value<String> name = const Value.absent(),
                Value<int> orderIndex = const Value.absent(),
                Value<int> foundationalLevel = const Value.absent(),
                Value<String> membersJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => KpGroupsCompanion.insert(
                id: id,
                version: version,
                updatedAt: updatedAt,
                deviceId: deviceId,
                deletedAt: deletedAt,
                canvasId: canvasId,
                name: name,
                orderIndex: orderIndex,
                foundationalLevel: foundationalLevel,
                membersJson: membersJson,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$KpGroupsTable, KpGroupRow>(table),
                  BaseReferences<_$AppDatabase, $KpGroupsTable, KpGroupRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$KpGroupsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $KpGroupsTable,
      KpGroupRow,
      $$KpGroupsTableFilterComposer,
      $$KpGroupsTableOrderingComposer,
      $$KpGroupsTableAnnotationComposer,
      $$KpGroupsTableCreateCompanionBuilder,
      $$KpGroupsTableUpdateCompanionBuilder,
      (KpGroupRow, BaseReferences<_$AppDatabase, $KpGroupsTable, KpGroupRow>),
      KpGroupRow,
      PrefetchHooks Function()
    >;
typedef $$HomeworksTableCreateCompanionBuilder = HomeworksCompanion Function({
  required String id,
  Value<int> version,
  required DateTime updatedAt,
  required String deviceId,
  Value<DateTime?> deletedAt,
  required String canvasId,
  Value<String> title,
  Value<String> kpIdsJson,
  Value<String> itemsJson,
  Value<int> rowid,
});
typedef $$HomeworksTableUpdateCompanionBuilder = HomeworksCompanion Function({
  Value<String> id,
  Value<int> version,
  Value<DateTime> updatedAt,
  Value<String> deviceId,
  Value<DateTime?> deletedAt,
  Value<String> canvasId,
  Value<String> title,
  Value<String> kpIdsJson,
  Value<String> itemsJson,
  Value<int> rowid,
});

class $$HomeworksTableFilterComposer
    extends Composer<_$AppDatabase, $HomeworksTable> {
  $$HomeworksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get canvasId => $composableBuilder(
    column: $table.canvasId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kpIdsJson => $composableBuilder(
    column: $table.kpIdsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get itemsJson => $composableBuilder(
    column: $table.itemsJson,
    builder: (column) => ColumnFilters(column),
  );
}

class $$HomeworksTableOrderingComposer
    extends Composer<_$AppDatabase, $HomeworksTable> {
  $$HomeworksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get canvasId => $composableBuilder(
    column: $table.canvasId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kpIdsJson => $composableBuilder(
    column: $table.kpIdsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get itemsJson => $composableBuilder(
    column: $table.itemsJson,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$HomeworksTableAnnotationComposer
    extends Composer<_$AppDatabase, $HomeworksTable> {
  $$HomeworksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get version =>
      $composableBuilder(column: $table.version, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  GeneratedColumn<DateTime> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<String> get canvasId =>
      $composableBuilder(column: $table.canvasId, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get kpIdsJson =>
      $composableBuilder(column: $table.kpIdsJson, builder: (column) => column);

  GeneratedColumn<String> get itemsJson =>
      $composableBuilder(column: $table.itemsJson, builder: (column) => column);
}

class $$HomeworksTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $HomeworksTable,
          HomeworkRow,
          $$HomeworksTableFilterComposer,
          $$HomeworksTableOrderingComposer,
          $$HomeworksTableAnnotationComposer,
          $$HomeworksTableCreateCompanionBuilder,
          $$HomeworksTableUpdateCompanionBuilder,
          (
            HomeworkRow,
            BaseReferences<_$AppDatabase, $HomeworksTable, HomeworkRow>,
          ),
          HomeworkRow,
          PrefetchHooks Function()
        > {
  $$HomeworksTableTableManager(_$AppDatabase db, $HomeworksTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$HomeworksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$HomeworksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$HomeworksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<int> version = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<String> deviceId = const Value.absent(),
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<String> canvasId = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> kpIdsJson = const Value.absent(),
                Value<String> itemsJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => HomeworksCompanion(
                id: id,
                version: version,
                updatedAt: updatedAt,
                deviceId: deviceId,
                deletedAt: deletedAt,
                canvasId: canvasId,
                title: title,
                kpIdsJson: kpIdsJson,
                itemsJson: itemsJson,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                Value<int> version = const Value.absent(),
                required DateTime updatedAt,
                required String deviceId,
                Value<DateTime?> deletedAt = const Value.absent(),
                required String canvasId,
                Value<String> title = const Value.absent(),
                Value<String> kpIdsJson = const Value.absent(),
                Value<String> itemsJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => HomeworksCompanion.insert(
                id: id,
                version: version,
                updatedAt: updatedAt,
                deviceId: deviceId,
                deletedAt: deletedAt,
                canvasId: canvasId,
                title: title,
                kpIdsJson: kpIdsJson,
                itemsJson: itemsJson,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$HomeworksTable, HomeworkRow>(table),
                  BaseReferences<_$AppDatabase, $HomeworksTable, HomeworkRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$HomeworksTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $HomeworksTable,
      HomeworkRow,
      $$HomeworksTableFilterComposer,
      $$HomeworksTableOrderingComposer,
      $$HomeworksTableAnnotationComposer,
      $$HomeworksTableCreateCompanionBuilder,
      $$HomeworksTableUpdateCompanionBuilder,
      (
        HomeworkRow,
        BaseReferences<_$AppDatabase, $HomeworksTable, HomeworkRow>,
      ),
      HomeworkRow,
      PrefetchHooks Function()
    >;
typedef $$AiSessionsTableCreateCompanionBuilder = AiSessionsCompanion Function({
  required String id,
  Value<int> version,
  required DateTime updatedAt,
  required String deviceId,
  Value<DateTime?> deletedAt,
  Value<String> type,
  Value<String> targetRef,
  Value<String> title,
  Value<String?> kpId,
  Value<String?> modelId,
  Value<String> tutorState,
  Value<String?> difficulty,
  Value<int> rowid,
});
typedef $$AiSessionsTableUpdateCompanionBuilder = AiSessionsCompanion Function({
  Value<String> id,
  Value<int> version,
  Value<DateTime> updatedAt,
  Value<String> deviceId,
  Value<DateTime?> deletedAt,
  Value<String> type,
  Value<String> targetRef,
  Value<String> title,
  Value<String?> kpId,
  Value<String?> modelId,
  Value<String> tutorState,
  Value<String?> difficulty,
  Value<int> rowid,
});

class $$AiSessionsTableFilterComposer
    extends Composer<_$AppDatabase, $AiSessionsTable> {
  $$AiSessionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get targetRef => $composableBuilder(
    column: $table.targetRef,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kpId => $composableBuilder(
    column: $table.kpId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get modelId => $composableBuilder(
    column: $table.modelId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tutorState => $composableBuilder(
    column: $table.tutorState,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get difficulty => $composableBuilder(
    column: $table.difficulty,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AiSessionsTableOrderingComposer
    extends Composer<_$AppDatabase, $AiSessionsTable> {
  $$AiSessionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get targetRef => $composableBuilder(
    column: $table.targetRef,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kpId => $composableBuilder(
    column: $table.kpId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get modelId => $composableBuilder(
    column: $table.modelId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tutorState => $composableBuilder(
    column: $table.tutorState,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get difficulty => $composableBuilder(
    column: $table.difficulty,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AiSessionsTableAnnotationComposer
    extends Composer<_$AppDatabase, $AiSessionsTable> {
  $$AiSessionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get version =>
      $composableBuilder(column: $table.version, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  GeneratedColumn<DateTime> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<String> get targetRef =>
      $composableBuilder(column: $table.targetRef, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get kpId =>
      $composableBuilder(column: $table.kpId, builder: (column) => column);

  GeneratedColumn<String> get modelId =>
      $composableBuilder(column: $table.modelId, builder: (column) => column);

  GeneratedColumn<String> get tutorState => $composableBuilder(
    column: $table.tutorState,
    builder: (column) => column,
  );

  GeneratedColumn<String> get difficulty => $composableBuilder(
    column: $table.difficulty,
    builder: (column) => column,
  );
}

class $$AiSessionsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AiSessionsTable,
          AiSessionRow,
          $$AiSessionsTableFilterComposer,
          $$AiSessionsTableOrderingComposer,
          $$AiSessionsTableAnnotationComposer,
          $$AiSessionsTableCreateCompanionBuilder,
          $$AiSessionsTableUpdateCompanionBuilder,
          (
            AiSessionRow,
            BaseReferences<_$AppDatabase, $AiSessionsTable, AiSessionRow>,
          ),
          AiSessionRow,
          PrefetchHooks Function()
        > {
  $$AiSessionsTableTableManager(_$AppDatabase db, $AiSessionsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AiSessionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AiSessionsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AiSessionsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<int> version = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<String> deviceId = const Value.absent(),
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<String> type = const Value.absent(),
                Value<String> targetRef = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String?> kpId = const Value.absent(),
                Value<String?> modelId = const Value.absent(),
                Value<String> tutorState = const Value.absent(),
                Value<String?> difficulty = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AiSessionsCompanion(
                id: id,
                version: version,
                updatedAt: updatedAt,
                deviceId: deviceId,
                deletedAt: deletedAt,
                type: type,
                targetRef: targetRef,
                title: title,
                kpId: kpId,
                modelId: modelId,
                tutorState: tutorState,
                difficulty: difficulty,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                Value<int> version = const Value.absent(),
                required DateTime updatedAt,
                required String deviceId,
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<String> type = const Value.absent(),
                Value<String> targetRef = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String?> kpId = const Value.absent(),
                Value<String?> modelId = const Value.absent(),
                Value<String> tutorState = const Value.absent(),
                Value<String?> difficulty = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AiSessionsCompanion.insert(
                id: id,
                version: version,
                updatedAt: updatedAt,
                deviceId: deviceId,
                deletedAt: deletedAt,
                type: type,
                targetRef: targetRef,
                title: title,
                kpId: kpId,
                modelId: modelId,
                tutorState: tutorState,
                difficulty: difficulty,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$AiSessionsTable, AiSessionRow>(table),
                  BaseReferences<_$AppDatabase, $AiSessionsTable, AiSessionRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AiSessionsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AiSessionsTable,
      AiSessionRow,
      $$AiSessionsTableFilterComposer,
      $$AiSessionsTableOrderingComposer,
      $$AiSessionsTableAnnotationComposer,
      $$AiSessionsTableCreateCompanionBuilder,
      $$AiSessionsTableUpdateCompanionBuilder,
      (
        AiSessionRow,
        BaseReferences<_$AppDatabase, $AiSessionsTable, AiSessionRow>,
      ),
      AiSessionRow,
      PrefetchHooks Function()
    >;
typedef $$AiMessagesTableCreateCompanionBuilder = AiMessagesCompanion Function({
  required String id,
  Value<int> version,
  required DateTime updatedAt,
  required String deviceId,
  Value<DateTime?> deletedAt,
  required String sessionId,
  required String role,
  Value<String> contentMd,
  Value<int?> tokens,
  Value<int?> latencyMs,
  Value<String?> modelId,
  Value<int> rowid,
});
typedef $$AiMessagesTableUpdateCompanionBuilder = AiMessagesCompanion Function({
  Value<String> id,
  Value<int> version,
  Value<DateTime> updatedAt,
  Value<String> deviceId,
  Value<DateTime?> deletedAt,
  Value<String> sessionId,
  Value<String> role,
  Value<String> contentMd,
  Value<int?> tokens,
  Value<int?> latencyMs,
  Value<String?> modelId,
  Value<int> rowid,
});

class $$AiMessagesTableFilterComposer
    extends Composer<_$AppDatabase, $AiMessagesTable> {
  $$AiMessagesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sessionId => $composableBuilder(
    column: $table.sessionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get role => $composableBuilder(
    column: $table.role,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get contentMd => $composableBuilder(
    column: $table.contentMd,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get tokens => $composableBuilder(
    column: $table.tokens,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get latencyMs => $composableBuilder(
    column: $table.latencyMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get modelId => $composableBuilder(
    column: $table.modelId,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AiMessagesTableOrderingComposer
    extends Composer<_$AppDatabase, $AiMessagesTable> {
  $$AiMessagesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sessionId => $composableBuilder(
    column: $table.sessionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get role => $composableBuilder(
    column: $table.role,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get contentMd => $composableBuilder(
    column: $table.contentMd,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get tokens => $composableBuilder(
    column: $table.tokens,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get latencyMs => $composableBuilder(
    column: $table.latencyMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get modelId => $composableBuilder(
    column: $table.modelId,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AiMessagesTableAnnotationComposer
    extends Composer<_$AppDatabase, $AiMessagesTable> {
  $$AiMessagesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get version =>
      $composableBuilder(column: $table.version, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  GeneratedColumn<DateTime> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<String> get sessionId =>
      $composableBuilder(column: $table.sessionId, builder: (column) => column);

  GeneratedColumn<String> get role =>
      $composableBuilder(column: $table.role, builder: (column) => column);

  GeneratedColumn<String> get contentMd =>
      $composableBuilder(column: $table.contentMd, builder: (column) => column);

  GeneratedColumn<int> get tokens =>
      $composableBuilder(column: $table.tokens, builder: (column) => column);

  GeneratedColumn<int> get latencyMs =>
      $composableBuilder(column: $table.latencyMs, builder: (column) => column);

  GeneratedColumn<String> get modelId =>
      $composableBuilder(column: $table.modelId, builder: (column) => column);
}

class $$AiMessagesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AiMessagesTable,
          AiMessageRow,
          $$AiMessagesTableFilterComposer,
          $$AiMessagesTableOrderingComposer,
          $$AiMessagesTableAnnotationComposer,
          $$AiMessagesTableCreateCompanionBuilder,
          $$AiMessagesTableUpdateCompanionBuilder,
          (
            AiMessageRow,
            BaseReferences<_$AppDatabase, $AiMessagesTable, AiMessageRow>,
          ),
          AiMessageRow,
          PrefetchHooks Function()
        > {
  $$AiMessagesTableTableManager(_$AppDatabase db, $AiMessagesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AiMessagesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AiMessagesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AiMessagesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<int> version = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<String> deviceId = const Value.absent(),
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<String> sessionId = const Value.absent(),
                Value<String> role = const Value.absent(),
                Value<String> contentMd = const Value.absent(),
                Value<int?> tokens = const Value.absent(),
                Value<int?> latencyMs = const Value.absent(),
                Value<String?> modelId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AiMessagesCompanion(
                id: id,
                version: version,
                updatedAt: updatedAt,
                deviceId: deviceId,
                deletedAt: deletedAt,
                sessionId: sessionId,
                role: role,
                contentMd: contentMd,
                tokens: tokens,
                latencyMs: latencyMs,
                modelId: modelId,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                Value<int> version = const Value.absent(),
                required DateTime updatedAt,
                required String deviceId,
                Value<DateTime?> deletedAt = const Value.absent(),
                required String sessionId,
                required String role,
                Value<String> contentMd = const Value.absent(),
                Value<int?> tokens = const Value.absent(),
                Value<int?> latencyMs = const Value.absent(),
                Value<String?> modelId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AiMessagesCompanion.insert(
                id: id,
                version: version,
                updatedAt: updatedAt,
                deviceId: deviceId,
                deletedAt: deletedAt,
                sessionId: sessionId,
                role: role,
                contentMd: contentMd,
                tokens: tokens,
                latencyMs: latencyMs,
                modelId: modelId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$AiMessagesTable, AiMessageRow>(table),
                  BaseReferences<_$AppDatabase, $AiMessagesTable, AiMessageRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AiMessagesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AiMessagesTable,
      AiMessageRow,
      $$AiMessagesTableFilterComposer,
      $$AiMessagesTableOrderingComposer,
      $$AiMessagesTableAnnotationComposer,
      $$AiMessagesTableCreateCompanionBuilder,
      $$AiMessagesTableUpdateCompanionBuilder,
      (
        AiMessageRow,
        BaseReferences<_$AppDatabase, $AiMessagesTable, AiMessageRow>,
      ),
      AiMessageRow,
      PrefetchHooks Function()
    >;
typedef $$AiProvidersTableCreateCompanionBuilder =
    AiProvidersCompanion Function({
      required String id,
      required String name,
      required String type,
      required String protocol,
      Value<String> baseUrl,
      Value<String> apiKeyRef,
      Value<String> models,
      Value<bool> isDefault,
      Value<bool> enabled,
      Value<int> rowid,
    });
typedef $$AiProvidersTableUpdateCompanionBuilder =
    AiProvidersCompanion Function({
      Value<String> id,
      Value<String> name,
      Value<String> type,
      Value<String> protocol,
      Value<String> baseUrl,
      Value<String> apiKeyRef,
      Value<String> models,
      Value<bool> isDefault,
      Value<bool> enabled,
      Value<int> rowid,
    });

class $$AiProvidersTableFilterComposer
    extends Composer<_$AppDatabase, $AiProvidersTable> {
  $$AiProvidersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get protocol => $composableBuilder(
    column: $table.protocol,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get baseUrl => $composableBuilder(
    column: $table.baseUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get apiKeyRef => $composableBuilder(
    column: $table.apiKeyRef,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get models => $composableBuilder(
    column: $table.models,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isDefault => $composableBuilder(
    column: $table.isDefault,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get enabled => $composableBuilder(
    column: $table.enabled,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AiProvidersTableOrderingComposer
    extends Composer<_$AppDatabase, $AiProvidersTable> {
  $$AiProvidersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get protocol => $composableBuilder(
    column: $table.protocol,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get baseUrl => $composableBuilder(
    column: $table.baseUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get apiKeyRef => $composableBuilder(
    column: $table.apiKeyRef,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get models => $composableBuilder(
    column: $table.models,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isDefault => $composableBuilder(
    column: $table.isDefault,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get enabled => $composableBuilder(
    column: $table.enabled,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AiProvidersTableAnnotationComposer
    extends Composer<_$AppDatabase, $AiProvidersTable> {
  $$AiProvidersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<String> get protocol =>
      $composableBuilder(column: $table.protocol, builder: (column) => column);

  GeneratedColumn<String> get baseUrl =>
      $composableBuilder(column: $table.baseUrl, builder: (column) => column);

  GeneratedColumn<String> get apiKeyRef =>
      $composableBuilder(column: $table.apiKeyRef, builder: (column) => column);

  GeneratedColumn<String> get models =>
      $composableBuilder(column: $table.models, builder: (column) => column);

  GeneratedColumn<bool> get isDefault =>
      $composableBuilder(column: $table.isDefault, builder: (column) => column);

  GeneratedColumn<bool> get enabled =>
      $composableBuilder(column: $table.enabled, builder: (column) => column);
}

class $$AiProvidersTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AiProvidersTable,
          AiProviderRow,
          $$AiProvidersTableFilterComposer,
          $$AiProvidersTableOrderingComposer,
          $$AiProvidersTableAnnotationComposer,
          $$AiProvidersTableCreateCompanionBuilder,
          $$AiProvidersTableUpdateCompanionBuilder,
          (
            AiProviderRow,
            BaseReferences<_$AppDatabase, $AiProvidersTable, AiProviderRow>,
          ),
          AiProviderRow,
          PrefetchHooks Function()
        > {
  $$AiProvidersTableTableManager(_$AppDatabase db, $AiProvidersTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AiProvidersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AiProvidersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AiProvidersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> type = const Value.absent(),
                Value<String> protocol = const Value.absent(),
                Value<String> baseUrl = const Value.absent(),
                Value<String> apiKeyRef = const Value.absent(),
                Value<String> models = const Value.absent(),
                Value<bool> isDefault = const Value.absent(),
                Value<bool> enabled = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AiProvidersCompanion(
                id: id,
                name: name,
                type: type,
                protocol: protocol,
                baseUrl: baseUrl,
                apiKeyRef: apiKeyRef,
                models: models,
                isDefault: isDefault,
                enabled: enabled,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                required String type,
                required String protocol,
                Value<String> baseUrl = const Value.absent(),
                Value<String> apiKeyRef = const Value.absent(),
                Value<String> models = const Value.absent(),
                Value<bool> isDefault = const Value.absent(),
                Value<bool> enabled = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AiProvidersCompanion.insert(
                id: id,
                name: name,
                type: type,
                protocol: protocol,
                baseUrl: baseUrl,
                apiKeyRef: apiKeyRef,
                models: models,
                isDefault: isDefault,
                enabled: enabled,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$AiProvidersTable, AiProviderRow>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $AiProvidersTable,
                    AiProviderRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AiProvidersTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AiProvidersTable,
      AiProviderRow,
      $$AiProvidersTableFilterComposer,
      $$AiProvidersTableOrderingComposer,
      $$AiProvidersTableAnnotationComposer,
      $$AiProvidersTableCreateCompanionBuilder,
      $$AiProvidersTableUpdateCompanionBuilder,
      (
        AiProviderRow,
        BaseReferences<_$AppDatabase, $AiProvidersTable, AiProviderRow>,
      ),
      AiProviderRow,
      PrefetchHooks Function()
    >;
typedef $$AiTaskRoutesTableCreateCompanionBuilder =
    AiTaskRoutesCompanion Function({
      required String id,
      required String aiTask,
      required String providerId,
      Value<String?> apiKeyRefOverride,
      Value<String?> endpointOverride,
      Value<int> rowid,
    });
typedef $$AiTaskRoutesTableUpdateCompanionBuilder =
    AiTaskRoutesCompanion Function({
      Value<String> id,
      Value<String> aiTask,
      Value<String> providerId,
      Value<String?> apiKeyRefOverride,
      Value<String?> endpointOverride,
      Value<int> rowid,
    });

class $$AiTaskRoutesTableFilterComposer
    extends Composer<_$AppDatabase, $AiTaskRoutesTable> {
  $$AiTaskRoutesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get aiTask => $composableBuilder(
    column: $table.aiTask,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get providerId => $composableBuilder(
    column: $table.providerId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get apiKeyRefOverride => $composableBuilder(
    column: $table.apiKeyRefOverride,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get endpointOverride => $composableBuilder(
    column: $table.endpointOverride,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AiTaskRoutesTableOrderingComposer
    extends Composer<_$AppDatabase, $AiTaskRoutesTable> {
  $$AiTaskRoutesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get aiTask => $composableBuilder(
    column: $table.aiTask,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get providerId => $composableBuilder(
    column: $table.providerId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get apiKeyRefOverride => $composableBuilder(
    column: $table.apiKeyRefOverride,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get endpointOverride => $composableBuilder(
    column: $table.endpointOverride,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AiTaskRoutesTableAnnotationComposer
    extends Composer<_$AppDatabase, $AiTaskRoutesTable> {
  $$AiTaskRoutesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get aiTask =>
      $composableBuilder(column: $table.aiTask, builder: (column) => column);

  GeneratedColumn<String> get providerId => $composableBuilder(
    column: $table.providerId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get apiKeyRefOverride => $composableBuilder(
    column: $table.apiKeyRefOverride,
    builder: (column) => column,
  );

  GeneratedColumn<String> get endpointOverride => $composableBuilder(
    column: $table.endpointOverride,
    builder: (column) => column,
  );
}

class $$AiTaskRoutesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AiTaskRoutesTable,
          AiTaskRouteRow,
          $$AiTaskRoutesTableFilterComposer,
          $$AiTaskRoutesTableOrderingComposer,
          $$AiTaskRoutesTableAnnotationComposer,
          $$AiTaskRoutesTableCreateCompanionBuilder,
          $$AiTaskRoutesTableUpdateCompanionBuilder,
          (
            AiTaskRouteRow,
            BaseReferences<_$AppDatabase, $AiTaskRoutesTable, AiTaskRouteRow>,
          ),
          AiTaskRouteRow,
          PrefetchHooks Function()
        > {
  $$AiTaskRoutesTableTableManager(_$AppDatabase db, $AiTaskRoutesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AiTaskRoutesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AiTaskRoutesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AiTaskRoutesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> aiTask = const Value.absent(),
                Value<String> providerId = const Value.absent(),
                Value<String?> apiKeyRefOverride = const Value.absent(),
                Value<String?> endpointOverride = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AiTaskRoutesCompanion(
                id: id,
                aiTask: aiTask,
                providerId: providerId,
                apiKeyRefOverride: apiKeyRefOverride,
                endpointOverride: endpointOverride,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String aiTask,
                required String providerId,
                Value<String?> apiKeyRefOverride = const Value.absent(),
                Value<String?> endpointOverride = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AiTaskRoutesCompanion.insert(
                id: id,
                aiTask: aiTask,
                providerId: providerId,
                apiKeyRefOverride: apiKeyRefOverride,
                endpointOverride: endpointOverride,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$AiTaskRoutesTable, AiTaskRouteRow>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $AiTaskRoutesTable,
                    AiTaskRouteRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AiTaskRoutesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AiTaskRoutesTable,
      AiTaskRouteRow,
      $$AiTaskRoutesTableFilterComposer,
      $$AiTaskRoutesTableOrderingComposer,
      $$AiTaskRoutesTableAnnotationComposer,
      $$AiTaskRoutesTableCreateCompanionBuilder,
      $$AiTaskRoutesTableUpdateCompanionBuilder,
      (
        AiTaskRouteRow,
        BaseReferences<_$AppDatabase, $AiTaskRoutesTable, AiTaskRouteRow>,
      ),
      AiTaskRouteRow,
      PrefetchHooks Function()
    >;
typedef $$SyncOutboxTableCreateCompanionBuilder = SyncOutboxCompanion Function({
  Value<int> id,
  required String entityTable,
  required String entityId,
  required String op,
  required String payloadJson,
  required String deviceId,
  Value<int> baseVersion,
  Value<int> retryCount,
  Value<String> status,
  required DateTime createdAt,
});
typedef $$SyncOutboxTableUpdateCompanionBuilder = SyncOutboxCompanion Function({
  Value<int> id,
  Value<String> entityTable,
  Value<String> entityId,
  Value<String> op,
  Value<String> payloadJson,
  Value<String> deviceId,
  Value<int> baseVersion,
  Value<int> retryCount,
  Value<String> status,
  Value<DateTime> createdAt,
});

class $$SyncOutboxTableFilterComposer
    extends Composer<_$AppDatabase, $SyncOutboxTable> {
  $$SyncOutboxTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get entityTable => $composableBuilder(
    column: $table.entityTable,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get entityId => $composableBuilder(
    column: $table.entityId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get op => $composableBuilder(
    column: $table.op,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get baseVersion => $composableBuilder(
    column: $table.baseVersion,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get retryCount => $composableBuilder(
    column: $table.retryCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SyncOutboxTableOrderingComposer
    extends Composer<_$AppDatabase, $SyncOutboxTable> {
  $$SyncOutboxTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get entityTable => $composableBuilder(
    column: $table.entityTable,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get entityId => $composableBuilder(
    column: $table.entityId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get op => $composableBuilder(
    column: $table.op,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get baseVersion => $composableBuilder(
    column: $table.baseVersion,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get retryCount => $composableBuilder(
    column: $table.retryCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SyncOutboxTableAnnotationComposer
    extends Composer<_$AppDatabase, $SyncOutboxTable> {
  $$SyncOutboxTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get entityTable => $composableBuilder(
    column: $table.entityTable,
    builder: (column) => column,
  );

  GeneratedColumn<String> get entityId =>
      $composableBuilder(column: $table.entityId, builder: (column) => column);

  GeneratedColumn<String> get op =>
      $composableBuilder(column: $table.op, builder: (column) => column);

  GeneratedColumn<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  GeneratedColumn<int> get baseVersion => $composableBuilder(
    column: $table.baseVersion,
    builder: (column) => column,
  );

  GeneratedColumn<int> get retryCount => $composableBuilder(
    column: $table.retryCount,
    builder: (column) => column,
  );

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$SyncOutboxTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SyncOutboxTable,
          SyncOutboxRow,
          $$SyncOutboxTableFilterComposer,
          $$SyncOutboxTableOrderingComposer,
          $$SyncOutboxTableAnnotationComposer,
          $$SyncOutboxTableCreateCompanionBuilder,
          $$SyncOutboxTableUpdateCompanionBuilder,
          (
            SyncOutboxRow,
            BaseReferences<_$AppDatabase, $SyncOutboxTable, SyncOutboxRow>,
          ),
          SyncOutboxRow,
          PrefetchHooks Function()
        > {
  $$SyncOutboxTableTableManager(_$AppDatabase db, $SyncOutboxTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncOutboxTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncOutboxTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncOutboxTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> entityTable = const Value.absent(),
                Value<String> entityId = const Value.absent(),
                Value<String> op = const Value.absent(),
                Value<String> payloadJson = const Value.absent(),
                Value<String> deviceId = const Value.absent(),
                Value<int> baseVersion = const Value.absent(),
                Value<int> retryCount = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
              }) => SyncOutboxCompanion(
                id: id,
                entityTable: entityTable,
                entityId: entityId,
                op: op,
                payloadJson: payloadJson,
                deviceId: deviceId,
                baseVersion: baseVersion,
                retryCount: retryCount,
                status: status,
                createdAt: createdAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String entityTable,
                required String entityId,
                required String op,
                required String payloadJson,
                required String deviceId,
                Value<int> baseVersion = const Value.absent(),
                Value<int> retryCount = const Value.absent(),
                Value<String> status = const Value.absent(),
                required DateTime createdAt,
              }) => SyncOutboxCompanion.insert(
                id: id,
                entityTable: entityTable,
                entityId: entityId,
                op: op,
                payloadJson: payloadJson,
                deviceId: deviceId,
                baseVersion: baseVersion,
                retryCount: retryCount,
                status: status,
                createdAt: createdAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SyncOutboxTable, SyncOutboxRow>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $SyncOutboxTable,
                    SyncOutboxRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SyncOutboxTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SyncOutboxTable,
      SyncOutboxRow,
      $$SyncOutboxTableFilterComposer,
      $$SyncOutboxTableOrderingComposer,
      $$SyncOutboxTableAnnotationComposer,
      $$SyncOutboxTableCreateCompanionBuilder,
      $$SyncOutboxTableUpdateCompanionBuilder,
      (
        SyncOutboxRow,
        BaseReferences<_$AppDatabase, $SyncOutboxTable, SyncOutboxRow>,
      ),
      SyncOutboxRow,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$NotebooksTableTableManager get notebooks =>
      $$NotebooksTableTableManager(_db, _db.notebooks);
  $$NotesTableTableManager get notes =>
      $$NotesTableTableManager(_db, _db.notes);
  $$KnowledgePointsTableTableManager get knowledgePoints =>
      $$KnowledgePointsTableTableManager(_db, _db.knowledgePoints);
  $$PrerequisiteEdgesTableTableManager get prerequisiteEdges =>
      $$PrerequisiteEdgesTableTableManager(_db, _db.prerequisiteEdges);
  $$MasteryRecordsTableTableManager get masteryRecords =>
      $$MasteryRecordsTableTableManager(_db, _db.masteryRecords);
  $$CardsTableTableManager get cards =>
      $$CardsTableTableManager(_db, _db.cards);
  $$CanvasesTableTableManager get canvases =>
      $$CanvasesTableTableManager(_db, _db.canvases);
  $$CanvasNodesTableTableManager get canvasNodes =>
      $$CanvasNodesTableTableManager(_db, _db.canvasNodes);
  $$CanvasEdgesTableTableManager get canvasEdges =>
      $$CanvasEdgesTableTableManager(_db, _db.canvasEdges);
  $$KpGroupsTableTableManager get kpGroups =>
      $$KpGroupsTableTableManager(_db, _db.kpGroups);
  $$HomeworksTableTableManager get homeworks =>
      $$HomeworksTableTableManager(_db, _db.homeworks);
  $$AiSessionsTableTableManager get aiSessions =>
      $$AiSessionsTableTableManager(_db, _db.aiSessions);
  $$AiMessagesTableTableManager get aiMessages =>
      $$AiMessagesTableTableManager(_db, _db.aiMessages);
  $$AiProvidersTableTableManager get aiProviders =>
      $$AiProvidersTableTableManager(_db, _db.aiProviders);
  $$AiTaskRoutesTableTableManager get aiTaskRoutes =>
      $$AiTaskRoutesTableTableManager(_db, _db.aiTaskRoutes);
  $$SyncOutboxTableTableManager get syncOutbox =>
      $$SyncOutboxTableTableManager(_db, _db.syncOutbox);
}
