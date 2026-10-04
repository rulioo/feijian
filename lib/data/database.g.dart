// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $PeersTable extends Peers with TableInfo<$PeersTable, PeerRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PeersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _deviceTypeMeta =
      const VerificationMeta('deviceType');
  @override
  late final GeneratedColumn<String> deviceType = GeneratedColumn<String>(
      'device_type', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _osMeta = const VerificationMeta('os');
  @override
  late final GeneratedColumn<String> os = GeneratedColumn<String>(
      'os', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _iconMeta = const VerificationMeta('icon');
  @override
  late final GeneratedColumn<String> icon = GeneratedColumn<String>(
      'icon', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _avatarMeta = const VerificationMeta('avatar');
  @override
  late final GeneratedColumn<Uint8List> avatar = GeneratedColumn<Uint8List>(
      'avatar', aliasedName, true,
      type: DriftSqlType.blob, requiredDuringInsert: false);
  static const VerificationMeta _lastIpMeta = const VerificationMeta('lastIp');
  @override
  late final GeneratedColumn<String> lastIp = GeneratedColumn<String>(
      'last_ip', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _lastSeenMeta =
      const VerificationMeta('lastSeen');
  @override
  late final GeneratedColumn<int> lastSeen = GeneratedColumn<int>(
      'last_seen', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _isTrustedMeta =
      const VerificationMeta('isTrusted');
  @override
  late final GeneratedColumn<bool> isTrusted = GeneratedColumn<bool>(
      'is_trusted', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("is_trusted" IN (0, 1))'),
      defaultValue: const Constant(false));
  @override
  List<GeneratedColumn> get $columns =>
      [id, name, deviceType, os, icon, avatar, lastIp, lastSeen, isTrusted];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'peer';
  @override
  VerificationContext validateIntegrity(Insertable<PeerRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('device_type')) {
      context.handle(
          _deviceTypeMeta,
          deviceType.isAcceptableOrUnknown(
              data['device_type']!, _deviceTypeMeta));
    } else if (isInserting) {
      context.missing(_deviceTypeMeta);
    }
    if (data.containsKey('os')) {
      context.handle(_osMeta, os.isAcceptableOrUnknown(data['os']!, _osMeta));
    }
    if (data.containsKey('icon')) {
      context.handle(
          _iconMeta, icon.isAcceptableOrUnknown(data['icon']!, _iconMeta));
    }
    if (data.containsKey('avatar')) {
      context.handle(_avatarMeta,
          avatar.isAcceptableOrUnknown(data['avatar']!, _avatarMeta));
    }
    if (data.containsKey('last_ip')) {
      context.handle(_lastIpMeta,
          lastIp.isAcceptableOrUnknown(data['last_ip']!, _lastIpMeta));
    }
    if (data.containsKey('last_seen')) {
      context.handle(_lastSeenMeta,
          lastSeen.isAcceptableOrUnknown(data['last_seen']!, _lastSeenMeta));
    }
    if (data.containsKey('is_trusted')) {
      context.handle(_isTrustedMeta,
          isTrusted.isAcceptableOrUnknown(data['is_trusted']!, _isTrustedMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PeerRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PeerRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      deviceType: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}device_type'])!,
      os: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}os']),
      icon: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}icon']),
      avatar: attachedDatabase.typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}avatar']),
      lastIp: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}last_ip']),
      lastSeen: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}last_seen']),
      isTrusted: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}is_trusted'])!,
    );
  }

  @override
  $PeersTable createAlias(String alias) {
    return $PeersTable(attachedDatabase, alias);
  }
}

class PeerRow extends DataClass implements Insertable<PeerRow> {
  /// Device UUID, generated once on first install. The identity everything else
  /// is keyed on — never the name, which the user can change at any time.
  final String id;
  final String name;

  /// `windows` / `android` / `ios`. Stored as text rather than an int index so
  /// the file stays readable and a reordering of the enum cannot silently
  /// reinterpret every existing row.
  final String deviceType;

  /// Free-form OS description, e.g. "Windows 11 23H2". Display only.
  final String? os;
  final String? icon;

  /// Optional custom avatar, uploaded by the peer.
  final Uint8List? avatar;
  final String? lastIp;

  /// Milliseconds since the epoch.
  ///
  /// Deliberately nullable and advisory: it is the peer's own claim about when
  /// it announced, and §4.5 already establishes that a peer's clock is not to
  /// be trusted for anything that matters.
  final int? lastSeen;

  /// Trusted peers may auto-accept file offers (§6.4).
  final bool isTrusted;
  const PeerRow(
      {required this.id,
      required this.name,
      required this.deviceType,
      this.os,
      this.icon,
      this.avatar,
      this.lastIp,
      this.lastSeen,
      required this.isTrusted});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    map['device_type'] = Variable<String>(deviceType);
    if (!nullToAbsent || os != null) {
      map['os'] = Variable<String>(os);
    }
    if (!nullToAbsent || icon != null) {
      map['icon'] = Variable<String>(icon);
    }
    if (!nullToAbsent || avatar != null) {
      map['avatar'] = Variable<Uint8List>(avatar);
    }
    if (!nullToAbsent || lastIp != null) {
      map['last_ip'] = Variable<String>(lastIp);
    }
    if (!nullToAbsent || lastSeen != null) {
      map['last_seen'] = Variable<int>(lastSeen);
    }
    map['is_trusted'] = Variable<bool>(isTrusted);
    return map;
  }

  PeersCompanion toCompanion(bool nullToAbsent) {
    return PeersCompanion(
      id: Value(id),
      name: Value(name),
      deviceType: Value(deviceType),
      os: os == null && nullToAbsent ? const Value.absent() : Value(os),
      icon: icon == null && nullToAbsent ? const Value.absent() : Value(icon),
      avatar:
          avatar == null && nullToAbsent ? const Value.absent() : Value(avatar),
      lastIp:
          lastIp == null && nullToAbsent ? const Value.absent() : Value(lastIp),
      lastSeen: lastSeen == null && nullToAbsent
          ? const Value.absent()
          : Value(lastSeen),
      isTrusted: Value(isTrusted),
    );
  }

  factory PeerRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PeerRow(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      deviceType: serializer.fromJson<String>(json['deviceType']),
      os: serializer.fromJson<String?>(json['os']),
      icon: serializer.fromJson<String?>(json['icon']),
      avatar: serializer.fromJson<Uint8List?>(json['avatar']),
      lastIp: serializer.fromJson<String?>(json['lastIp']),
      lastSeen: serializer.fromJson<int?>(json['lastSeen']),
      isTrusted: serializer.fromJson<bool>(json['isTrusted']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'deviceType': serializer.toJson<String>(deviceType),
      'os': serializer.toJson<String?>(os),
      'icon': serializer.toJson<String?>(icon),
      'avatar': serializer.toJson<Uint8List?>(avatar),
      'lastIp': serializer.toJson<String?>(lastIp),
      'lastSeen': serializer.toJson<int?>(lastSeen),
      'isTrusted': serializer.toJson<bool>(isTrusted),
    };
  }

  PeerRow copyWith(
          {String? id,
          String? name,
          String? deviceType,
          Value<String?> os = const Value.absent(),
          Value<String?> icon = const Value.absent(),
          Value<Uint8List?> avatar = const Value.absent(),
          Value<String?> lastIp = const Value.absent(),
          Value<int?> lastSeen = const Value.absent(),
          bool? isTrusted}) =>
      PeerRow(
        id: id ?? this.id,
        name: name ?? this.name,
        deviceType: deviceType ?? this.deviceType,
        os: os.present ? os.value : this.os,
        icon: icon.present ? icon.value : this.icon,
        avatar: avatar.present ? avatar.value : this.avatar,
        lastIp: lastIp.present ? lastIp.value : this.lastIp,
        lastSeen: lastSeen.present ? lastSeen.value : this.lastSeen,
        isTrusted: isTrusted ?? this.isTrusted,
      );
  PeerRow copyWithCompanion(PeersCompanion data) {
    return PeerRow(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      deviceType:
          data.deviceType.present ? data.deviceType.value : this.deviceType,
      os: data.os.present ? data.os.value : this.os,
      icon: data.icon.present ? data.icon.value : this.icon,
      avatar: data.avatar.present ? data.avatar.value : this.avatar,
      lastIp: data.lastIp.present ? data.lastIp.value : this.lastIp,
      lastSeen: data.lastSeen.present ? data.lastSeen.value : this.lastSeen,
      isTrusted: data.isTrusted.present ? data.isTrusted.value : this.isTrusted,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PeerRow(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('deviceType: $deviceType, ')
          ..write('os: $os, ')
          ..write('icon: $icon, ')
          ..write('avatar: $avatar, ')
          ..write('lastIp: $lastIp, ')
          ..write('lastSeen: $lastSeen, ')
          ..write('isTrusted: $isTrusted')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, name, deviceType, os, icon,
      $driftBlobEquality.hash(avatar), lastIp, lastSeen, isTrusted);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PeerRow &&
          other.id == this.id &&
          other.name == this.name &&
          other.deviceType == this.deviceType &&
          other.os == this.os &&
          other.icon == this.icon &&
          $driftBlobEquality.equals(other.avatar, this.avatar) &&
          other.lastIp == this.lastIp &&
          other.lastSeen == this.lastSeen &&
          other.isTrusted == this.isTrusted);
}

class PeersCompanion extends UpdateCompanion<PeerRow> {
  final Value<String> id;
  final Value<String> name;
  final Value<String> deviceType;
  final Value<String?> os;
  final Value<String?> icon;
  final Value<Uint8List?> avatar;
  final Value<String?> lastIp;
  final Value<int?> lastSeen;
  final Value<bool> isTrusted;
  final Value<int> rowid;
  const PeersCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.deviceType = const Value.absent(),
    this.os = const Value.absent(),
    this.icon = const Value.absent(),
    this.avatar = const Value.absent(),
    this.lastIp = const Value.absent(),
    this.lastSeen = const Value.absent(),
    this.isTrusted = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PeersCompanion.insert({
    required String id,
    required String name,
    required String deviceType,
    this.os = const Value.absent(),
    this.icon = const Value.absent(),
    this.avatar = const Value.absent(),
    this.lastIp = const Value.absent(),
    this.lastSeen = const Value.absent(),
    this.isTrusted = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        name = Value(name),
        deviceType = Value(deviceType);
  static Insertable<PeerRow> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<String>? deviceType,
    Expression<String>? os,
    Expression<String>? icon,
    Expression<Uint8List>? avatar,
    Expression<String>? lastIp,
    Expression<int>? lastSeen,
    Expression<bool>? isTrusted,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (deviceType != null) 'device_type': deviceType,
      if (os != null) 'os': os,
      if (icon != null) 'icon': icon,
      if (avatar != null) 'avatar': avatar,
      if (lastIp != null) 'last_ip': lastIp,
      if (lastSeen != null) 'last_seen': lastSeen,
      if (isTrusted != null) 'is_trusted': isTrusted,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PeersCompanion copyWith(
      {Value<String>? id,
      Value<String>? name,
      Value<String>? deviceType,
      Value<String?>? os,
      Value<String?>? icon,
      Value<Uint8List?>? avatar,
      Value<String?>? lastIp,
      Value<int?>? lastSeen,
      Value<bool>? isTrusted,
      Value<int>? rowid}) {
    return PeersCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      deviceType: deviceType ?? this.deviceType,
      os: os ?? this.os,
      icon: icon ?? this.icon,
      avatar: avatar ?? this.avatar,
      lastIp: lastIp ?? this.lastIp,
      lastSeen: lastSeen ?? this.lastSeen,
      isTrusted: isTrusted ?? this.isTrusted,
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
    if (deviceType.present) {
      map['device_type'] = Variable<String>(deviceType.value);
    }
    if (os.present) {
      map['os'] = Variable<String>(os.value);
    }
    if (icon.present) {
      map['icon'] = Variable<String>(icon.value);
    }
    if (avatar.present) {
      map['avatar'] = Variable<Uint8List>(avatar.value);
    }
    if (lastIp.present) {
      map['last_ip'] = Variable<String>(lastIp.value);
    }
    if (lastSeen.present) {
      map['last_seen'] = Variable<int>(lastSeen.value);
    }
    if (isTrusted.present) {
      map['is_trusted'] = Variable<bool>(isTrusted.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PeersCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('deviceType: $deviceType, ')
          ..write('os: $os, ')
          ..write('icon: $icon, ')
          ..write('avatar: $avatar, ')
          ..write('lastIp: $lastIp, ')
          ..write('lastSeen: $lastSeen, ')
          ..write('isTrusted: $isTrusted, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ConversationsTable extends Conversations
    with TableInfo<$ConversationsTable, ConversationRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ConversationsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _peerIdMeta = const VerificationMeta('peerId');
  @override
  late final GeneratedColumn<String> peerId = GeneratedColumn<String>(
      'peer_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
      'created_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _lastMsgAtMeta =
      const VerificationMeta('lastMsgAt');
  @override
  late final GeneratedColumn<int> lastMsgAt = GeneratedColumn<int>(
      'last_msg_at', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _unreadCountMeta =
      const VerificationMeta('unreadCount');
  @override
  late final GeneratedColumn<int> unreadCount = GeneratedColumn<int>(
      'unread_count', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _draftMeta = const VerificationMeta('draft');
  @override
  late final GeneratedColumn<String> draft = GeneratedColumn<String>(
      'draft', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns =>
      [id, peerId, createdAt, lastMsgAt, unreadCount, draft];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'conversation';
  @override
  VerificationContext validateIntegrity(Insertable<ConversationRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('peer_id')) {
      context.handle(_peerIdMeta,
          peerId.isAcceptableOrUnknown(data['peer_id']!, _peerIdMeta));
    } else if (isInserting) {
      context.missing(_peerIdMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('last_msg_at')) {
      context.handle(
          _lastMsgAtMeta,
          lastMsgAt.isAcceptableOrUnknown(
              data['last_msg_at']!, _lastMsgAtMeta));
    }
    if (data.containsKey('unread_count')) {
      context.handle(
          _unreadCountMeta,
          unreadCount.isAcceptableOrUnknown(
              data['unread_count']!, _unreadCountMeta));
    }
    if (data.containsKey('draft')) {
      context.handle(
          _draftMeta, draft.isAcceptableOrUnknown(data['draft']!, _draftMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ConversationRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ConversationRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      peerId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}peer_id'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}created_at'])!,
      lastMsgAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}last_msg_at']),
      unreadCount: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}unread_count'])!,
      draft: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}draft']),
    );
  }

  @override
  $ConversationsTable createAlias(String alias) {
    return $ConversationsTable(attachedDatabase, alias);
  }
}

class ConversationRow extends DataClass implements Insertable<ConversationRow> {
  final String id;

  /// Deliberately *not* a foreign key, unlike §5.1's original draft.
  ///
  /// The `peer` table is a cache of what devices have announced about
  /// themselves; a conversation is the user's own data. Referencing one from the
  /// other makes forgetting a device — the one action that removes a peer row —
  /// either impossible (SQLite's default `NO ACTION` refuses the delete) or
  /// destructive (`ON DELETE CASCADE` would erase the history with it, with no
  /// undo, as a side effect of tidying a device list).
  ///
  /// `message.peer_id` below already has no reference, so a peer id with no peer
  /// row is a state this schema tolerates regardless; a constraint that only
  /// holds for one of the two tables would not even buy consistency.
  final String peerId;
  final int createdAt;

  /// Timestamp of the newest message, for sorting the device list by recency.
  final int? lastMsgAt;
  final int unreadCount;

  /// Unsent draft text, so switching devices does not lose what was typed.
  final String? draft;
  const ConversationRow(
      {required this.id,
      required this.peerId,
      required this.createdAt,
      this.lastMsgAt,
      required this.unreadCount,
      this.draft});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['peer_id'] = Variable<String>(peerId);
    map['created_at'] = Variable<int>(createdAt);
    if (!nullToAbsent || lastMsgAt != null) {
      map['last_msg_at'] = Variable<int>(lastMsgAt);
    }
    map['unread_count'] = Variable<int>(unreadCount);
    if (!nullToAbsent || draft != null) {
      map['draft'] = Variable<String>(draft);
    }
    return map;
  }

  ConversationsCompanion toCompanion(bool nullToAbsent) {
    return ConversationsCompanion(
      id: Value(id),
      peerId: Value(peerId),
      createdAt: Value(createdAt),
      lastMsgAt: lastMsgAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastMsgAt),
      unreadCount: Value(unreadCount),
      draft:
          draft == null && nullToAbsent ? const Value.absent() : Value(draft),
    );
  }

  factory ConversationRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ConversationRow(
      id: serializer.fromJson<String>(json['id']),
      peerId: serializer.fromJson<String>(json['peerId']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      lastMsgAt: serializer.fromJson<int?>(json['lastMsgAt']),
      unreadCount: serializer.fromJson<int>(json['unreadCount']),
      draft: serializer.fromJson<String?>(json['draft']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'peerId': serializer.toJson<String>(peerId),
      'createdAt': serializer.toJson<int>(createdAt),
      'lastMsgAt': serializer.toJson<int?>(lastMsgAt),
      'unreadCount': serializer.toJson<int>(unreadCount),
      'draft': serializer.toJson<String?>(draft),
    };
  }

  ConversationRow copyWith(
          {String? id,
          String? peerId,
          int? createdAt,
          Value<int?> lastMsgAt = const Value.absent(),
          int? unreadCount,
          Value<String?> draft = const Value.absent()}) =>
      ConversationRow(
        id: id ?? this.id,
        peerId: peerId ?? this.peerId,
        createdAt: createdAt ?? this.createdAt,
        lastMsgAt: lastMsgAt.present ? lastMsgAt.value : this.lastMsgAt,
        unreadCount: unreadCount ?? this.unreadCount,
        draft: draft.present ? draft.value : this.draft,
      );
  ConversationRow copyWithCompanion(ConversationsCompanion data) {
    return ConversationRow(
      id: data.id.present ? data.id.value : this.id,
      peerId: data.peerId.present ? data.peerId.value : this.peerId,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      lastMsgAt: data.lastMsgAt.present ? data.lastMsgAt.value : this.lastMsgAt,
      unreadCount:
          data.unreadCount.present ? data.unreadCount.value : this.unreadCount,
      draft: data.draft.present ? data.draft.value : this.draft,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ConversationRow(')
          ..write('id: $id, ')
          ..write('peerId: $peerId, ')
          ..write('createdAt: $createdAt, ')
          ..write('lastMsgAt: $lastMsgAt, ')
          ..write('unreadCount: $unreadCount, ')
          ..write('draft: $draft')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, peerId, createdAt, lastMsgAt, unreadCount, draft);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ConversationRow &&
          other.id == this.id &&
          other.peerId == this.peerId &&
          other.createdAt == this.createdAt &&
          other.lastMsgAt == this.lastMsgAt &&
          other.unreadCount == this.unreadCount &&
          other.draft == this.draft);
}

class ConversationsCompanion extends UpdateCompanion<ConversationRow> {
  final Value<String> id;
  final Value<String> peerId;
  final Value<int> createdAt;
  final Value<int?> lastMsgAt;
  final Value<int> unreadCount;
  final Value<String?> draft;
  final Value<int> rowid;
  const ConversationsCompanion({
    this.id = const Value.absent(),
    this.peerId = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.lastMsgAt = const Value.absent(),
    this.unreadCount = const Value.absent(),
    this.draft = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ConversationsCompanion.insert({
    required String id,
    required String peerId,
    required int createdAt,
    this.lastMsgAt = const Value.absent(),
    this.unreadCount = const Value.absent(),
    this.draft = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        peerId = Value(peerId),
        createdAt = Value(createdAt);
  static Insertable<ConversationRow> custom({
    Expression<String>? id,
    Expression<String>? peerId,
    Expression<int>? createdAt,
    Expression<int>? lastMsgAt,
    Expression<int>? unreadCount,
    Expression<String>? draft,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (peerId != null) 'peer_id': peerId,
      if (createdAt != null) 'created_at': createdAt,
      if (lastMsgAt != null) 'last_msg_at': lastMsgAt,
      if (unreadCount != null) 'unread_count': unreadCount,
      if (draft != null) 'draft': draft,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ConversationsCompanion copyWith(
      {Value<String>? id,
      Value<String>? peerId,
      Value<int>? createdAt,
      Value<int?>? lastMsgAt,
      Value<int>? unreadCount,
      Value<String?>? draft,
      Value<int>? rowid}) {
    return ConversationsCompanion(
      id: id ?? this.id,
      peerId: peerId ?? this.peerId,
      createdAt: createdAt ?? this.createdAt,
      lastMsgAt: lastMsgAt ?? this.lastMsgAt,
      unreadCount: unreadCount ?? this.unreadCount,
      draft: draft ?? this.draft,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (peerId.present) {
      map['peer_id'] = Variable<String>(peerId.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (lastMsgAt.present) {
      map['last_msg_at'] = Variable<int>(lastMsgAt.value);
    }
    if (unreadCount.present) {
      map['unread_count'] = Variable<int>(unreadCount.value);
    }
    if (draft.present) {
      map['draft'] = Variable<String>(draft.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ConversationsCompanion(')
          ..write('id: $id, ')
          ..write('peerId: $peerId, ')
          ..write('createdAt: $createdAt, ')
          ..write('lastMsgAt: $lastMsgAt, ')
          ..write('unreadCount: $unreadCount, ')
          ..write('draft: $draft, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MessagesTable extends Messages
    with TableInfo<$MessagesTable, MessageRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MessagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _conversationIdMeta =
      const VerificationMeta('conversationId');
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
      'conversation_id', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES conversation (id)'));
  static const VerificationMeta _peerIdMeta = const VerificationMeta('peerId');
  @override
  late final GeneratedColumn<String> peerId = GeneratedColumn<String>(
      'peer_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _directionMeta =
      const VerificationMeta('direction');
  @override
  late final GeneratedColumn<String> direction = GeneratedColumn<String>(
      'direction', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
      'type', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _bodyMeta = const VerificationMeta('body');
  @override
  late final GeneratedColumn<String> body = GeneratedColumn<String>(
      'text', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
      'status', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
      'created_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _deliveredAtMeta =
      const VerificationMeta('deliveredAt');
  @override
  late final GeneratedColumn<int> deliveredAt = GeneratedColumn<int>(
      'delivered_at', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _retryCountMeta =
      const VerificationMeta('retryCount');
  @override
  late final GeneratedColumn<int> retryCount = GeneratedColumn<int>(
      'retry_count', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  @override
  List<GeneratedColumn> get $columns => [
        id,
        conversationId,
        peerId,
        direction,
        type,
        body,
        status,
        createdAt,
        deliveredAt,
        retryCount
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'message';
  @override
  VerificationContext validateIntegrity(Insertable<MessageRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('conversation_id')) {
      context.handle(
          _conversationIdMeta,
          conversationId.isAcceptableOrUnknown(
              data['conversation_id']!, _conversationIdMeta));
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('peer_id')) {
      context.handle(_peerIdMeta,
          peerId.isAcceptableOrUnknown(data['peer_id']!, _peerIdMeta));
    } else if (isInserting) {
      context.missing(_peerIdMeta);
    }
    if (data.containsKey('direction')) {
      context.handle(_directionMeta,
          direction.isAcceptableOrUnknown(data['direction']!, _directionMeta));
    } else if (isInserting) {
      context.missing(_directionMeta);
    }
    if (data.containsKey('type')) {
      context.handle(
          _typeMeta, type.isAcceptableOrUnknown(data['type']!, _typeMeta));
    } else if (isInserting) {
      context.missing(_typeMeta);
    }
    if (data.containsKey('text')) {
      context.handle(
          _bodyMeta, body.isAcceptableOrUnknown(data['text']!, _bodyMeta));
    }
    if (data.containsKey('status')) {
      context.handle(_statusMeta,
          status.isAcceptableOrUnknown(data['status']!, _statusMeta));
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('delivered_at')) {
      context.handle(
          _deliveredAtMeta,
          deliveredAt.isAcceptableOrUnknown(
              data['delivered_at']!, _deliveredAtMeta));
    }
    if (data.containsKey('retry_count')) {
      context.handle(
          _retryCountMeta,
          retryCount.isAcceptableOrUnknown(
              data['retry_count']!, _retryCountMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  MessageRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MessageRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      conversationId: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}conversation_id'])!,
      peerId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}peer_id'])!,
      direction: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}direction'])!,
      type: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}type'])!,
      body: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}text']),
      status: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}status'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}created_at'])!,
      deliveredAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}delivered_at']),
      retryCount: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}retry_count'])!,
    );
  }

  @override
  $MessagesTable createAlias(String alias) {
    return $MessagesTable(attachedDatabase, alias);
  }
}

class MessageRow extends DataClass implements Insertable<MessageRow> {
  /// The `msgId` from the wire, not a locally generated key.
  ///
  /// This is what makes a re-delivered message harmless: the sender reuses its
  /// `msgId` when it retries (§4.5), so a plain insert collides on the primary
  /// key and can be ignored rather than stored twice. The in-memory dedupe
  /// window covers the running session; this covers the restart the window
  /// cannot survive.
  final String id;
  final String conversationId;
  final String peerId;

  /// `in` / `out`, from this device's point of view.
  final String direction;

  /// `text` / `file` / `image` / `folder` / `system`.
  final String type;

  /// The message body.
  ///
  /// The Dart accessor is `body` because a member named `text` would shadow the
  /// `text()` column builder from `Table` and make this declaration impossible
  /// to write. The SQL column stays `text`, as the design document has it.
  final String? body;

  /// `pending` / `sent` / `delivered` / `failed` / `received`.
  final String status;

  /// This device's local clock, not the peer's. It is the sort key (§4.5), so
  /// it must never be something a remote clock can move.
  final int createdAt;
  final int? deliveredAt;
  final int retryCount;
  const MessageRow(
      {required this.id,
      required this.conversationId,
      required this.peerId,
      required this.direction,
      required this.type,
      this.body,
      required this.status,
      required this.createdAt,
      this.deliveredAt,
      required this.retryCount});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['conversation_id'] = Variable<String>(conversationId);
    map['peer_id'] = Variable<String>(peerId);
    map['direction'] = Variable<String>(direction);
    map['type'] = Variable<String>(type);
    if (!nullToAbsent || body != null) {
      map['text'] = Variable<String>(body);
    }
    map['status'] = Variable<String>(status);
    map['created_at'] = Variable<int>(createdAt);
    if (!nullToAbsent || deliveredAt != null) {
      map['delivered_at'] = Variable<int>(deliveredAt);
    }
    map['retry_count'] = Variable<int>(retryCount);
    return map;
  }

  MessagesCompanion toCompanion(bool nullToAbsent) {
    return MessagesCompanion(
      id: Value(id),
      conversationId: Value(conversationId),
      peerId: Value(peerId),
      direction: Value(direction),
      type: Value(type),
      body: body == null && nullToAbsent ? const Value.absent() : Value(body),
      status: Value(status),
      createdAt: Value(createdAt),
      deliveredAt: deliveredAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deliveredAt),
      retryCount: Value(retryCount),
    );
  }

  factory MessageRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MessageRow(
      id: serializer.fromJson<String>(json['id']),
      conversationId: serializer.fromJson<String>(json['conversationId']),
      peerId: serializer.fromJson<String>(json['peerId']),
      direction: serializer.fromJson<String>(json['direction']),
      type: serializer.fromJson<String>(json['type']),
      body: serializer.fromJson<String?>(json['body']),
      status: serializer.fromJson<String>(json['status']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      deliveredAt: serializer.fromJson<int?>(json['deliveredAt']),
      retryCount: serializer.fromJson<int>(json['retryCount']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'conversationId': serializer.toJson<String>(conversationId),
      'peerId': serializer.toJson<String>(peerId),
      'direction': serializer.toJson<String>(direction),
      'type': serializer.toJson<String>(type),
      'body': serializer.toJson<String?>(body),
      'status': serializer.toJson<String>(status),
      'createdAt': serializer.toJson<int>(createdAt),
      'deliveredAt': serializer.toJson<int?>(deliveredAt),
      'retryCount': serializer.toJson<int>(retryCount),
    };
  }

  MessageRow copyWith(
          {String? id,
          String? conversationId,
          String? peerId,
          String? direction,
          String? type,
          Value<String?> body = const Value.absent(),
          String? status,
          int? createdAt,
          Value<int?> deliveredAt = const Value.absent(),
          int? retryCount}) =>
      MessageRow(
        id: id ?? this.id,
        conversationId: conversationId ?? this.conversationId,
        peerId: peerId ?? this.peerId,
        direction: direction ?? this.direction,
        type: type ?? this.type,
        body: body.present ? body.value : this.body,
        status: status ?? this.status,
        createdAt: createdAt ?? this.createdAt,
        deliveredAt: deliveredAt.present ? deliveredAt.value : this.deliveredAt,
        retryCount: retryCount ?? this.retryCount,
      );
  MessageRow copyWithCompanion(MessagesCompanion data) {
    return MessageRow(
      id: data.id.present ? data.id.value : this.id,
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      peerId: data.peerId.present ? data.peerId.value : this.peerId,
      direction: data.direction.present ? data.direction.value : this.direction,
      type: data.type.present ? data.type.value : this.type,
      body: data.body.present ? data.body.value : this.body,
      status: data.status.present ? data.status.value : this.status,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      deliveredAt:
          data.deliveredAt.present ? data.deliveredAt.value : this.deliveredAt,
      retryCount:
          data.retryCount.present ? data.retryCount.value : this.retryCount,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MessageRow(')
          ..write('id: $id, ')
          ..write('conversationId: $conversationId, ')
          ..write('peerId: $peerId, ')
          ..write('direction: $direction, ')
          ..write('type: $type, ')
          ..write('body: $body, ')
          ..write('status: $status, ')
          ..write('createdAt: $createdAt, ')
          ..write('deliveredAt: $deliveredAt, ')
          ..write('retryCount: $retryCount')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, conversationId, peerId, direction, type,
      body, status, createdAt, deliveredAt, retryCount);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MessageRow &&
          other.id == this.id &&
          other.conversationId == this.conversationId &&
          other.peerId == this.peerId &&
          other.direction == this.direction &&
          other.type == this.type &&
          other.body == this.body &&
          other.status == this.status &&
          other.createdAt == this.createdAt &&
          other.deliveredAt == this.deliveredAt &&
          other.retryCount == this.retryCount);
}

class MessagesCompanion extends UpdateCompanion<MessageRow> {
  final Value<String> id;
  final Value<String> conversationId;
  final Value<String> peerId;
  final Value<String> direction;
  final Value<String> type;
  final Value<String?> body;
  final Value<String> status;
  final Value<int> createdAt;
  final Value<int?> deliveredAt;
  final Value<int> retryCount;
  final Value<int> rowid;
  const MessagesCompanion({
    this.id = const Value.absent(),
    this.conversationId = const Value.absent(),
    this.peerId = const Value.absent(),
    this.direction = const Value.absent(),
    this.type = const Value.absent(),
    this.body = const Value.absent(),
    this.status = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.deliveredAt = const Value.absent(),
    this.retryCount = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MessagesCompanion.insert({
    required String id,
    required String conversationId,
    required String peerId,
    required String direction,
    required String type,
    this.body = const Value.absent(),
    required String status,
    required int createdAt,
    this.deliveredAt = const Value.absent(),
    this.retryCount = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        conversationId = Value(conversationId),
        peerId = Value(peerId),
        direction = Value(direction),
        type = Value(type),
        status = Value(status),
        createdAt = Value(createdAt);
  static Insertable<MessageRow> custom({
    Expression<String>? id,
    Expression<String>? conversationId,
    Expression<String>? peerId,
    Expression<String>? direction,
    Expression<String>? type,
    Expression<String>? body,
    Expression<String>? status,
    Expression<int>? createdAt,
    Expression<int>? deliveredAt,
    Expression<int>? retryCount,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (conversationId != null) 'conversation_id': conversationId,
      if (peerId != null) 'peer_id': peerId,
      if (direction != null) 'direction': direction,
      if (type != null) 'type': type,
      if (body != null) 'text': body,
      if (status != null) 'status': status,
      if (createdAt != null) 'created_at': createdAt,
      if (deliveredAt != null) 'delivered_at': deliveredAt,
      if (retryCount != null) 'retry_count': retryCount,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MessagesCompanion copyWith(
      {Value<String>? id,
      Value<String>? conversationId,
      Value<String>? peerId,
      Value<String>? direction,
      Value<String>? type,
      Value<String?>? body,
      Value<String>? status,
      Value<int>? createdAt,
      Value<int?>? deliveredAt,
      Value<int>? retryCount,
      Value<int>? rowid}) {
    return MessagesCompanion(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      peerId: peerId ?? this.peerId,
      direction: direction ?? this.direction,
      type: type ?? this.type,
      body: body ?? this.body,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      deliveredAt: deliveredAt ?? this.deliveredAt,
      retryCount: retryCount ?? this.retryCount,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (peerId.present) {
      map['peer_id'] = Variable<String>(peerId.value);
    }
    if (direction.present) {
      map['direction'] = Variable<String>(direction.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (body.present) {
      map['text'] = Variable<String>(body.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (deliveredAt.present) {
      map['delivered_at'] = Variable<int>(deliveredAt.value);
    }
    if (retryCount.present) {
      map['retry_count'] = Variable<int>(retryCount.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MessagesCompanion(')
          ..write('id: $id, ')
          ..write('conversationId: $conversationId, ')
          ..write('peerId: $peerId, ')
          ..write('direction: $direction, ')
          ..write('type: $type, ')
          ..write('body: $body, ')
          ..write('status: $status, ')
          ..write('createdAt: $createdAt, ')
          ..write('deliveredAt: $deliveredAt, ')
          ..write('retryCount: $retryCount, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AttachmentsTable extends Attachments
    with TableInfo<$AttachmentsTable, AttachmentRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AttachmentsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _messageIdMeta =
      const VerificationMeta('messageId');
  @override
  late final GeneratedColumn<String> messageId = GeneratedColumn<String>(
      'message_id', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'REFERENCES message (id) ON DELETE CASCADE'));
  static const VerificationMeta _fileNameMeta =
      const VerificationMeta('fileName');
  @override
  late final GeneratedColumn<String> fileName = GeneratedColumn<String>(
      'file_name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _relPathMeta =
      const VerificationMeta('relPath');
  @override
  late final GeneratedColumn<String> relPath = GeneratedColumn<String>(
      'rel_path', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _sizeMeta = const VerificationMeta('size');
  @override
  late final GeneratedColumn<int> size = GeneratedColumn<int>(
      'size', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _mimeMeta = const VerificationMeta('mime');
  @override
  late final GeneratedColumn<String> mime = GeneratedColumn<String>(
      'mime', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _localPathMeta =
      const VerificationMeta('localPath');
  @override
  late final GeneratedColumn<String> localPath = GeneratedColumn<String>(
      'local_path', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _thumbPathMeta =
      const VerificationMeta('thumbPath');
  @override
  late final GeneratedColumn<String> thumbPath = GeneratedColumn<String>(
      'thumb_path', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _sha256Meta = const VerificationMeta('sha256');
  @override
  late final GeneratedColumn<String> sha256 = GeneratedColumn<String>(
      'sha256', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _stateMeta = const VerificationMeta('state');
  @override
  late final GeneratedColumn<String> state = GeneratedColumn<String>(
      'state', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _transferredMeta =
      const VerificationMeta('transferred');
  @override
  late final GeneratedColumn<int> transferred = GeneratedColumn<int>(
      'transferred', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  @override
  List<GeneratedColumn> get $columns => [
        id,
        messageId,
        fileName,
        relPath,
        size,
        mime,
        localPath,
        thumbPath,
        sha256,
        state,
        transferred
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'attachment';
  @override
  VerificationContext validateIntegrity(Insertable<AttachmentRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('message_id')) {
      context.handle(_messageIdMeta,
          messageId.isAcceptableOrUnknown(data['message_id']!, _messageIdMeta));
    } else if (isInserting) {
      context.missing(_messageIdMeta);
    }
    if (data.containsKey('file_name')) {
      context.handle(_fileNameMeta,
          fileName.isAcceptableOrUnknown(data['file_name']!, _fileNameMeta));
    } else if (isInserting) {
      context.missing(_fileNameMeta);
    }
    if (data.containsKey('rel_path')) {
      context.handle(_relPathMeta,
          relPath.isAcceptableOrUnknown(data['rel_path']!, _relPathMeta));
    }
    if (data.containsKey('size')) {
      context.handle(
          _sizeMeta, size.isAcceptableOrUnknown(data['size']!, _sizeMeta));
    } else if (isInserting) {
      context.missing(_sizeMeta);
    }
    if (data.containsKey('mime')) {
      context.handle(
          _mimeMeta, mime.isAcceptableOrUnknown(data['mime']!, _mimeMeta));
    }
    if (data.containsKey('local_path')) {
      context.handle(_localPathMeta,
          localPath.isAcceptableOrUnknown(data['local_path']!, _localPathMeta));
    }
    if (data.containsKey('thumb_path')) {
      context.handle(_thumbPathMeta,
          thumbPath.isAcceptableOrUnknown(data['thumb_path']!, _thumbPathMeta));
    }
    if (data.containsKey('sha256')) {
      context.handle(_sha256Meta,
          sha256.isAcceptableOrUnknown(data['sha256']!, _sha256Meta));
    }
    if (data.containsKey('state')) {
      context.handle(
          _stateMeta, state.isAcceptableOrUnknown(data['state']!, _stateMeta));
    } else if (isInserting) {
      context.missing(_stateMeta);
    }
    if (data.containsKey('transferred')) {
      context.handle(
          _transferredMeta,
          transferred.isAcceptableOrUnknown(
              data['transferred']!, _transferredMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AttachmentRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AttachmentRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      messageId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}message_id'])!,
      fileName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}file_name'])!,
      relPath: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}rel_path']),
      size: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}size'])!,
      mime: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}mime']),
      localPath: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}local_path']),
      thumbPath: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}thumb_path']),
      sha256: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}sha256']),
      state: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}state'])!,
      transferred: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}transferred'])!,
    );
  }

  @override
  $AttachmentsTable createAlias(String alias) {
    return $AttachmentsTable(attachedDatabase, alias);
  }
}

class AttachmentRow extends DataClass implements Insertable<AttachmentRow> {
  final String id;
  final String messageId;
  final String fileName;

  /// Path inside the transferred folder, for a folder transfer.
  final String? relPath;
  final int size;
  final String? mime;

  /// Where the file ended up on this device once received.
  final String? localPath;

  /// Cached thumbnail, so the chat list does not decode full images.
  final String? thumbPath;
  final String? sha256;

  /// `pending` / `downloading` / `done` / `failed` / `cancelled`.
  final String state;
  final int transferred;
  const AttachmentRow(
      {required this.id,
      required this.messageId,
      required this.fileName,
      this.relPath,
      required this.size,
      this.mime,
      this.localPath,
      this.thumbPath,
      this.sha256,
      required this.state,
      required this.transferred});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['message_id'] = Variable<String>(messageId);
    map['file_name'] = Variable<String>(fileName);
    if (!nullToAbsent || relPath != null) {
      map['rel_path'] = Variable<String>(relPath);
    }
    map['size'] = Variable<int>(size);
    if (!nullToAbsent || mime != null) {
      map['mime'] = Variable<String>(mime);
    }
    if (!nullToAbsent || localPath != null) {
      map['local_path'] = Variable<String>(localPath);
    }
    if (!nullToAbsent || thumbPath != null) {
      map['thumb_path'] = Variable<String>(thumbPath);
    }
    if (!nullToAbsent || sha256 != null) {
      map['sha256'] = Variable<String>(sha256);
    }
    map['state'] = Variable<String>(state);
    map['transferred'] = Variable<int>(transferred);
    return map;
  }

  AttachmentsCompanion toCompanion(bool nullToAbsent) {
    return AttachmentsCompanion(
      id: Value(id),
      messageId: Value(messageId),
      fileName: Value(fileName),
      relPath: relPath == null && nullToAbsent
          ? const Value.absent()
          : Value(relPath),
      size: Value(size),
      mime: mime == null && nullToAbsent ? const Value.absent() : Value(mime),
      localPath: localPath == null && nullToAbsent
          ? const Value.absent()
          : Value(localPath),
      thumbPath: thumbPath == null && nullToAbsent
          ? const Value.absent()
          : Value(thumbPath),
      sha256:
          sha256 == null && nullToAbsent ? const Value.absent() : Value(sha256),
      state: Value(state),
      transferred: Value(transferred),
    );
  }

  factory AttachmentRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AttachmentRow(
      id: serializer.fromJson<String>(json['id']),
      messageId: serializer.fromJson<String>(json['messageId']),
      fileName: serializer.fromJson<String>(json['fileName']),
      relPath: serializer.fromJson<String?>(json['relPath']),
      size: serializer.fromJson<int>(json['size']),
      mime: serializer.fromJson<String?>(json['mime']),
      localPath: serializer.fromJson<String?>(json['localPath']),
      thumbPath: serializer.fromJson<String?>(json['thumbPath']),
      sha256: serializer.fromJson<String?>(json['sha256']),
      state: serializer.fromJson<String>(json['state']),
      transferred: serializer.fromJson<int>(json['transferred']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'messageId': serializer.toJson<String>(messageId),
      'fileName': serializer.toJson<String>(fileName),
      'relPath': serializer.toJson<String?>(relPath),
      'size': serializer.toJson<int>(size),
      'mime': serializer.toJson<String?>(mime),
      'localPath': serializer.toJson<String?>(localPath),
      'thumbPath': serializer.toJson<String?>(thumbPath),
      'sha256': serializer.toJson<String?>(sha256),
      'state': serializer.toJson<String>(state),
      'transferred': serializer.toJson<int>(transferred),
    };
  }

  AttachmentRow copyWith(
          {String? id,
          String? messageId,
          String? fileName,
          Value<String?> relPath = const Value.absent(),
          int? size,
          Value<String?> mime = const Value.absent(),
          Value<String?> localPath = const Value.absent(),
          Value<String?> thumbPath = const Value.absent(),
          Value<String?> sha256 = const Value.absent(),
          String? state,
          int? transferred}) =>
      AttachmentRow(
        id: id ?? this.id,
        messageId: messageId ?? this.messageId,
        fileName: fileName ?? this.fileName,
        relPath: relPath.present ? relPath.value : this.relPath,
        size: size ?? this.size,
        mime: mime.present ? mime.value : this.mime,
        localPath: localPath.present ? localPath.value : this.localPath,
        thumbPath: thumbPath.present ? thumbPath.value : this.thumbPath,
        sha256: sha256.present ? sha256.value : this.sha256,
        state: state ?? this.state,
        transferred: transferred ?? this.transferred,
      );
  AttachmentRow copyWithCompanion(AttachmentsCompanion data) {
    return AttachmentRow(
      id: data.id.present ? data.id.value : this.id,
      messageId: data.messageId.present ? data.messageId.value : this.messageId,
      fileName: data.fileName.present ? data.fileName.value : this.fileName,
      relPath: data.relPath.present ? data.relPath.value : this.relPath,
      size: data.size.present ? data.size.value : this.size,
      mime: data.mime.present ? data.mime.value : this.mime,
      localPath: data.localPath.present ? data.localPath.value : this.localPath,
      thumbPath: data.thumbPath.present ? data.thumbPath.value : this.thumbPath,
      sha256: data.sha256.present ? data.sha256.value : this.sha256,
      state: data.state.present ? data.state.value : this.state,
      transferred:
          data.transferred.present ? data.transferred.value : this.transferred,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AttachmentRow(')
          ..write('id: $id, ')
          ..write('messageId: $messageId, ')
          ..write('fileName: $fileName, ')
          ..write('relPath: $relPath, ')
          ..write('size: $size, ')
          ..write('mime: $mime, ')
          ..write('localPath: $localPath, ')
          ..write('thumbPath: $thumbPath, ')
          ..write('sha256: $sha256, ')
          ..write('state: $state, ')
          ..write('transferred: $transferred')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, messageId, fileName, relPath, size, mime,
      localPath, thumbPath, sha256, state, transferred);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AttachmentRow &&
          other.id == this.id &&
          other.messageId == this.messageId &&
          other.fileName == this.fileName &&
          other.relPath == this.relPath &&
          other.size == this.size &&
          other.mime == this.mime &&
          other.localPath == this.localPath &&
          other.thumbPath == this.thumbPath &&
          other.sha256 == this.sha256 &&
          other.state == this.state &&
          other.transferred == this.transferred);
}

class AttachmentsCompanion extends UpdateCompanion<AttachmentRow> {
  final Value<String> id;
  final Value<String> messageId;
  final Value<String> fileName;
  final Value<String?> relPath;
  final Value<int> size;
  final Value<String?> mime;
  final Value<String?> localPath;
  final Value<String?> thumbPath;
  final Value<String?> sha256;
  final Value<String> state;
  final Value<int> transferred;
  final Value<int> rowid;
  const AttachmentsCompanion({
    this.id = const Value.absent(),
    this.messageId = const Value.absent(),
    this.fileName = const Value.absent(),
    this.relPath = const Value.absent(),
    this.size = const Value.absent(),
    this.mime = const Value.absent(),
    this.localPath = const Value.absent(),
    this.thumbPath = const Value.absent(),
    this.sha256 = const Value.absent(),
    this.state = const Value.absent(),
    this.transferred = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AttachmentsCompanion.insert({
    required String id,
    required String messageId,
    required String fileName,
    this.relPath = const Value.absent(),
    required int size,
    this.mime = const Value.absent(),
    this.localPath = const Value.absent(),
    this.thumbPath = const Value.absent(),
    this.sha256 = const Value.absent(),
    required String state,
    this.transferred = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        messageId = Value(messageId),
        fileName = Value(fileName),
        size = Value(size),
        state = Value(state);
  static Insertable<AttachmentRow> custom({
    Expression<String>? id,
    Expression<String>? messageId,
    Expression<String>? fileName,
    Expression<String>? relPath,
    Expression<int>? size,
    Expression<String>? mime,
    Expression<String>? localPath,
    Expression<String>? thumbPath,
    Expression<String>? sha256,
    Expression<String>? state,
    Expression<int>? transferred,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (messageId != null) 'message_id': messageId,
      if (fileName != null) 'file_name': fileName,
      if (relPath != null) 'rel_path': relPath,
      if (size != null) 'size': size,
      if (mime != null) 'mime': mime,
      if (localPath != null) 'local_path': localPath,
      if (thumbPath != null) 'thumb_path': thumbPath,
      if (sha256 != null) 'sha256': sha256,
      if (state != null) 'state': state,
      if (transferred != null) 'transferred': transferred,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AttachmentsCompanion copyWith(
      {Value<String>? id,
      Value<String>? messageId,
      Value<String>? fileName,
      Value<String?>? relPath,
      Value<int>? size,
      Value<String?>? mime,
      Value<String?>? localPath,
      Value<String?>? thumbPath,
      Value<String?>? sha256,
      Value<String>? state,
      Value<int>? transferred,
      Value<int>? rowid}) {
    return AttachmentsCompanion(
      id: id ?? this.id,
      messageId: messageId ?? this.messageId,
      fileName: fileName ?? this.fileName,
      relPath: relPath ?? this.relPath,
      size: size ?? this.size,
      mime: mime ?? this.mime,
      localPath: localPath ?? this.localPath,
      thumbPath: thumbPath ?? this.thumbPath,
      sha256: sha256 ?? this.sha256,
      state: state ?? this.state,
      transferred: transferred ?? this.transferred,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (messageId.present) {
      map['message_id'] = Variable<String>(messageId.value);
    }
    if (fileName.present) {
      map['file_name'] = Variable<String>(fileName.value);
    }
    if (relPath.present) {
      map['rel_path'] = Variable<String>(relPath.value);
    }
    if (size.present) {
      map['size'] = Variable<int>(size.value);
    }
    if (mime.present) {
      map['mime'] = Variable<String>(mime.value);
    }
    if (localPath.present) {
      map['local_path'] = Variable<String>(localPath.value);
    }
    if (thumbPath.present) {
      map['thumb_path'] = Variable<String>(thumbPath.value);
    }
    if (sha256.present) {
      map['sha256'] = Variable<String>(sha256.value);
    }
    if (state.present) {
      map['state'] = Variable<String>(state.value);
    }
    if (transferred.present) {
      map['transferred'] = Variable<int>(transferred.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AttachmentsCompanion(')
          ..write('id: $id, ')
          ..write('messageId: $messageId, ')
          ..write('fileName: $fileName, ')
          ..write('relPath: $relPath, ')
          ..write('size: $size, ')
          ..write('mime: $mime, ')
          ..write('localPath: $localPath, ')
          ..write('thumbPath: $thumbPath, ')
          ..write('sha256: $sha256, ')
          ..write('state: $state, ')
          ..write('transferred: $transferred, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $TransfersTable extends Transfers
    with TableInfo<$TransfersTable, TransferRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TransfersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _messageIdMeta =
      const VerificationMeta('messageId');
  @override
  late final GeneratedColumn<String> messageId = GeneratedColumn<String>(
      'message_id', aliasedName, true,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES message (id)'));
  static const VerificationMeta _attachmentIdMeta =
      const VerificationMeta('attachmentId');
  @override
  late final GeneratedColumn<String> attachmentId = GeneratedColumn<String>(
      'attachment_id', aliasedName, true,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES attachment (id)'));
  static const VerificationMeta _peerIdMeta = const VerificationMeta('peerId');
  @override
  late final GeneratedColumn<String> peerId = GeneratedColumn<String>(
      'peer_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _directionMeta =
      const VerificationMeta('direction');
  @override
  late final GeneratedColumn<String> direction = GeneratedColumn<String>(
      'direction', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _stateMeta = const VerificationMeta('state');
  @override
  late final GeneratedColumn<String> state = GeneratedColumn<String>(
      'state', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _bytesDoneMeta =
      const VerificationMeta('bytesDone');
  @override
  late final GeneratedColumn<int> bytesDone = GeneratedColumn<int>(
      'bytes_done', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _bytesTotalMeta =
      const VerificationMeta('bytesTotal');
  @override
  late final GeneratedColumn<int> bytesTotal = GeneratedColumn<int>(
      'bytes_total', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _tempPathMeta =
      const VerificationMeta('tempPath');
  @override
  late final GeneratedColumn<String> tempPath = GeneratedColumn<String>(
      'temp_path', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        messageId,
        attachmentId,
        peerId,
        direction,
        state,
        bytesDone,
        bytesTotal,
        tempPath,
        updatedAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'transfer';
  @override
  VerificationContext validateIntegrity(Insertable<TransferRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('message_id')) {
      context.handle(_messageIdMeta,
          messageId.isAcceptableOrUnknown(data['message_id']!, _messageIdMeta));
    }
    if (data.containsKey('attachment_id')) {
      context.handle(
          _attachmentIdMeta,
          attachmentId.isAcceptableOrUnknown(
              data['attachment_id']!, _attachmentIdMeta));
    }
    if (data.containsKey('peer_id')) {
      context.handle(_peerIdMeta,
          peerId.isAcceptableOrUnknown(data['peer_id']!, _peerIdMeta));
    } else if (isInserting) {
      context.missing(_peerIdMeta);
    }
    if (data.containsKey('direction')) {
      context.handle(_directionMeta,
          direction.isAcceptableOrUnknown(data['direction']!, _directionMeta));
    } else if (isInserting) {
      context.missing(_directionMeta);
    }
    if (data.containsKey('state')) {
      context.handle(
          _stateMeta, state.isAcceptableOrUnknown(data['state']!, _stateMeta));
    } else if (isInserting) {
      context.missing(_stateMeta);
    }
    if (data.containsKey('bytes_done')) {
      context.handle(_bytesDoneMeta,
          bytesDone.isAcceptableOrUnknown(data['bytes_done']!, _bytesDoneMeta));
    }
    if (data.containsKey('bytes_total')) {
      context.handle(
          _bytesTotalMeta,
          bytesTotal.isAcceptableOrUnknown(
              data['bytes_total']!, _bytesTotalMeta));
    } else if (isInserting) {
      context.missing(_bytesTotalMeta);
    }
    if (data.containsKey('temp_path')) {
      context.handle(_tempPathMeta,
          tempPath.isAcceptableOrUnknown(data['temp_path']!, _tempPathMeta));
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  TransferRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TransferRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      messageId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}message_id']),
      attachmentId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}attachment_id']),
      peerId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}peer_id'])!,
      direction: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}direction'])!,
      state: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}state'])!,
      bytesDone: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}bytes_done'])!,
      bytesTotal: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}bytes_total'])!,
      tempPath: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}temp_path']),
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $TransfersTable createAlias(String alias) {
    return $TransfersTable(attachedDatabase, alias);
  }
}

class TransferRow extends DataClass implements Insertable<TransferRow> {
  /// The `xferId` from the wire.
  final String id;
  final String? messageId;
  final String? attachmentId;
  final String peerId;
  final String direction;
  final String state;
  final int bytesDone;
  final int bytesTotal;

  /// The partial file. Kept so a resumed transfer continues rather than
  /// restarting — which for a large file over Wi-Fi is the difference between a
  /// feature and a nuisance.
  final String? tempPath;
  final int updatedAt;
  const TransferRow(
      {required this.id,
      this.messageId,
      this.attachmentId,
      required this.peerId,
      required this.direction,
      required this.state,
      required this.bytesDone,
      required this.bytesTotal,
      this.tempPath,
      required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    if (!nullToAbsent || messageId != null) {
      map['message_id'] = Variable<String>(messageId);
    }
    if (!nullToAbsent || attachmentId != null) {
      map['attachment_id'] = Variable<String>(attachmentId);
    }
    map['peer_id'] = Variable<String>(peerId);
    map['direction'] = Variable<String>(direction);
    map['state'] = Variable<String>(state);
    map['bytes_done'] = Variable<int>(bytesDone);
    map['bytes_total'] = Variable<int>(bytesTotal);
    if (!nullToAbsent || tempPath != null) {
      map['temp_path'] = Variable<String>(tempPath);
    }
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  TransfersCompanion toCompanion(bool nullToAbsent) {
    return TransfersCompanion(
      id: Value(id),
      messageId: messageId == null && nullToAbsent
          ? const Value.absent()
          : Value(messageId),
      attachmentId: attachmentId == null && nullToAbsent
          ? const Value.absent()
          : Value(attachmentId),
      peerId: Value(peerId),
      direction: Value(direction),
      state: Value(state),
      bytesDone: Value(bytesDone),
      bytesTotal: Value(bytesTotal),
      tempPath: tempPath == null && nullToAbsent
          ? const Value.absent()
          : Value(tempPath),
      updatedAt: Value(updatedAt),
    );
  }

  factory TransferRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TransferRow(
      id: serializer.fromJson<String>(json['id']),
      messageId: serializer.fromJson<String?>(json['messageId']),
      attachmentId: serializer.fromJson<String?>(json['attachmentId']),
      peerId: serializer.fromJson<String>(json['peerId']),
      direction: serializer.fromJson<String>(json['direction']),
      state: serializer.fromJson<String>(json['state']),
      bytesDone: serializer.fromJson<int>(json['bytesDone']),
      bytesTotal: serializer.fromJson<int>(json['bytesTotal']),
      tempPath: serializer.fromJson<String?>(json['tempPath']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'messageId': serializer.toJson<String?>(messageId),
      'attachmentId': serializer.toJson<String?>(attachmentId),
      'peerId': serializer.toJson<String>(peerId),
      'direction': serializer.toJson<String>(direction),
      'state': serializer.toJson<String>(state),
      'bytesDone': serializer.toJson<int>(bytesDone),
      'bytesTotal': serializer.toJson<int>(bytesTotal),
      'tempPath': serializer.toJson<String?>(tempPath),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  TransferRow copyWith(
          {String? id,
          Value<String?> messageId = const Value.absent(),
          Value<String?> attachmentId = const Value.absent(),
          String? peerId,
          String? direction,
          String? state,
          int? bytesDone,
          int? bytesTotal,
          Value<String?> tempPath = const Value.absent(),
          int? updatedAt}) =>
      TransferRow(
        id: id ?? this.id,
        messageId: messageId.present ? messageId.value : this.messageId,
        attachmentId:
            attachmentId.present ? attachmentId.value : this.attachmentId,
        peerId: peerId ?? this.peerId,
        direction: direction ?? this.direction,
        state: state ?? this.state,
        bytesDone: bytesDone ?? this.bytesDone,
        bytesTotal: bytesTotal ?? this.bytesTotal,
        tempPath: tempPath.present ? tempPath.value : this.tempPath,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  TransferRow copyWithCompanion(TransfersCompanion data) {
    return TransferRow(
      id: data.id.present ? data.id.value : this.id,
      messageId: data.messageId.present ? data.messageId.value : this.messageId,
      attachmentId: data.attachmentId.present
          ? data.attachmentId.value
          : this.attachmentId,
      peerId: data.peerId.present ? data.peerId.value : this.peerId,
      direction: data.direction.present ? data.direction.value : this.direction,
      state: data.state.present ? data.state.value : this.state,
      bytesDone: data.bytesDone.present ? data.bytesDone.value : this.bytesDone,
      bytesTotal:
          data.bytesTotal.present ? data.bytesTotal.value : this.bytesTotal,
      tempPath: data.tempPath.present ? data.tempPath.value : this.tempPath,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TransferRow(')
          ..write('id: $id, ')
          ..write('messageId: $messageId, ')
          ..write('attachmentId: $attachmentId, ')
          ..write('peerId: $peerId, ')
          ..write('direction: $direction, ')
          ..write('state: $state, ')
          ..write('bytesDone: $bytesDone, ')
          ..write('bytesTotal: $bytesTotal, ')
          ..write('tempPath: $tempPath, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, messageId, attachmentId, peerId,
      direction, state, bytesDone, bytesTotal, tempPath, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TransferRow &&
          other.id == this.id &&
          other.messageId == this.messageId &&
          other.attachmentId == this.attachmentId &&
          other.peerId == this.peerId &&
          other.direction == this.direction &&
          other.state == this.state &&
          other.bytesDone == this.bytesDone &&
          other.bytesTotal == this.bytesTotal &&
          other.tempPath == this.tempPath &&
          other.updatedAt == this.updatedAt);
}

class TransfersCompanion extends UpdateCompanion<TransferRow> {
  final Value<String> id;
  final Value<String?> messageId;
  final Value<String?> attachmentId;
  final Value<String> peerId;
  final Value<String> direction;
  final Value<String> state;
  final Value<int> bytesDone;
  final Value<int> bytesTotal;
  final Value<String?> tempPath;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const TransfersCompanion({
    this.id = const Value.absent(),
    this.messageId = const Value.absent(),
    this.attachmentId = const Value.absent(),
    this.peerId = const Value.absent(),
    this.direction = const Value.absent(),
    this.state = const Value.absent(),
    this.bytesDone = const Value.absent(),
    this.bytesTotal = const Value.absent(),
    this.tempPath = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TransfersCompanion.insert({
    required String id,
    this.messageId = const Value.absent(),
    this.attachmentId = const Value.absent(),
    required String peerId,
    required String direction,
    required String state,
    this.bytesDone = const Value.absent(),
    required int bytesTotal,
    this.tempPath = const Value.absent(),
    required int updatedAt,
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        peerId = Value(peerId),
        direction = Value(direction),
        state = Value(state),
        bytesTotal = Value(bytesTotal),
        updatedAt = Value(updatedAt);
  static Insertable<TransferRow> custom({
    Expression<String>? id,
    Expression<String>? messageId,
    Expression<String>? attachmentId,
    Expression<String>? peerId,
    Expression<String>? direction,
    Expression<String>? state,
    Expression<int>? bytesDone,
    Expression<int>? bytesTotal,
    Expression<String>? tempPath,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (messageId != null) 'message_id': messageId,
      if (attachmentId != null) 'attachment_id': attachmentId,
      if (peerId != null) 'peer_id': peerId,
      if (direction != null) 'direction': direction,
      if (state != null) 'state': state,
      if (bytesDone != null) 'bytes_done': bytesDone,
      if (bytesTotal != null) 'bytes_total': bytesTotal,
      if (tempPath != null) 'temp_path': tempPath,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TransfersCompanion copyWith(
      {Value<String>? id,
      Value<String?>? messageId,
      Value<String?>? attachmentId,
      Value<String>? peerId,
      Value<String>? direction,
      Value<String>? state,
      Value<int>? bytesDone,
      Value<int>? bytesTotal,
      Value<String?>? tempPath,
      Value<int>? updatedAt,
      Value<int>? rowid}) {
    return TransfersCompanion(
      id: id ?? this.id,
      messageId: messageId ?? this.messageId,
      attachmentId: attachmentId ?? this.attachmentId,
      peerId: peerId ?? this.peerId,
      direction: direction ?? this.direction,
      state: state ?? this.state,
      bytesDone: bytesDone ?? this.bytesDone,
      bytesTotal: bytesTotal ?? this.bytesTotal,
      tempPath: tempPath ?? this.tempPath,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (messageId.present) {
      map['message_id'] = Variable<String>(messageId.value);
    }
    if (attachmentId.present) {
      map['attachment_id'] = Variable<String>(attachmentId.value);
    }
    if (peerId.present) {
      map['peer_id'] = Variable<String>(peerId.value);
    }
    if (direction.present) {
      map['direction'] = Variable<String>(direction.value);
    }
    if (state.present) {
      map['state'] = Variable<String>(state.value);
    }
    if (bytesDone.present) {
      map['bytes_done'] = Variable<int>(bytesDone.value);
    }
    if (bytesTotal.present) {
      map['bytes_total'] = Variable<int>(bytesTotal.value);
    }
    if (tempPath.present) {
      map['temp_path'] = Variable<String>(tempPath.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TransfersCompanion(')
          ..write('id: $id, ')
          ..write('messageId: $messageId, ')
          ..write('attachmentId: $attachmentId, ')
          ..write('peerId: $peerId, ')
          ..write('direction: $direction, ')
          ..write('state: $state, ')
          ..write('bytesDone: $bytesDone, ')
          ..write('bytesTotal: $bytesTotal, ')
          ..write('tempPath: $tempPath, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SettingsTable extends Settings
    with TableInfo<$SettingsTable, SettingRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SettingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
      'key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
      'value', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'setting';
  @override
  VerificationContext validateIntegrity(Insertable<SettingRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
          _keyMeta, key.isAcceptableOrUnknown(data['key']!, _keyMeta));
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
          _valueMeta, value.isAcceptableOrUnknown(data['value']!, _valueMeta));
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  SettingRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SettingRow(
      key: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}key'])!,
      value: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}value'])!,
    );
  }

  @override
  $SettingsTable createAlias(String alias) {
    return $SettingsTable(attachedDatabase, alias);
  }
}

class SettingRow extends DataClass implements Insertable<SettingRow> {
  final String key;
  final String value;
  const SettingRow({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  SettingsCompanion toCompanion(bool nullToAbsent) {
    return SettingsCompanion(
      key: Value(key),
      value: Value(value),
    );
  }

  factory SettingRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SettingRow(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  SettingRow copyWith({String? key, String? value}) => SettingRow(
        key: key ?? this.key,
        value: value ?? this.value,
      );
  SettingRow copyWithCompanion(SettingsCompanion data) {
    return SettingRow(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SettingRow(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SettingRow &&
          other.key == this.key &&
          other.value == this.value);
}

class SettingsCompanion extends UpdateCompanion<SettingRow> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const SettingsCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SettingsCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  })  : key = Value(key),
        value = Value(value);
  static Insertable<SettingRow> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SettingsCompanion copyWith(
      {Value<String>? key, Value<String>? value, Value<int>? rowid}) {
    return SettingsCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SettingsCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $PeersTable peers = $PeersTable(this);
  late final $ConversationsTable conversations = $ConversationsTable(this);
  late final $MessagesTable messages = $MessagesTable(this);
  late final $AttachmentsTable attachments = $AttachmentsTable(this);
  late final $TransfersTable transfers = $TransfersTable(this);
  late final $SettingsTable settings = $SettingsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities =>
      [peers, conversations, messages, attachments, transfers, settings];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules(
        [
          WritePropagation(
            on: TableUpdateQuery.onTableName('message',
                limitUpdateKind: UpdateKind.delete),
            result: [
              TableUpdate('attachment', kind: UpdateKind.delete),
            ],
          ),
        ],
      );
}

typedef $$PeersTableCreateCompanionBuilder = PeersCompanion Function({
  required String id,
  required String name,
  required String deviceType,
  Value<String?> os,
  Value<String?> icon,
  Value<Uint8List?> avatar,
  Value<String?> lastIp,
  Value<int?> lastSeen,
  Value<bool> isTrusted,
  Value<int> rowid,
});
typedef $$PeersTableUpdateCompanionBuilder = PeersCompanion Function({
  Value<String> id,
  Value<String> name,
  Value<String> deviceType,
  Value<String?> os,
  Value<String?> icon,
  Value<Uint8List?> avatar,
  Value<String?> lastIp,
  Value<int?> lastSeen,
  Value<bool> isTrusted,
  Value<int> rowid,
});

class $$PeersTableFilterComposer extends Composer<_$AppDatabase, $PeersTable> {
  $$PeersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get deviceType => $composableBuilder(
      column: $table.deviceType, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get os => $composableBuilder(
      column: $table.os, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get icon => $composableBuilder(
      column: $table.icon, builder: (column) => ColumnFilters(column));

  ColumnFilters<Uint8List> get avatar => $composableBuilder(
      column: $table.avatar, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get lastIp => $composableBuilder(
      column: $table.lastIp, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get lastSeen => $composableBuilder(
      column: $table.lastSeen, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get isTrusted => $composableBuilder(
      column: $table.isTrusted, builder: (column) => ColumnFilters(column));
}

class $$PeersTableOrderingComposer
    extends Composer<_$AppDatabase, $PeersTable> {
  $$PeersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get deviceType => $composableBuilder(
      column: $table.deviceType, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get os => $composableBuilder(
      column: $table.os, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get icon => $composableBuilder(
      column: $table.icon, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<Uint8List> get avatar => $composableBuilder(
      column: $table.avatar, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get lastIp => $composableBuilder(
      column: $table.lastIp, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get lastSeen => $composableBuilder(
      column: $table.lastSeen, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get isTrusted => $composableBuilder(
      column: $table.isTrusted, builder: (column) => ColumnOrderings(column));
}

class $$PeersTableAnnotationComposer
    extends Composer<_$AppDatabase, $PeersTable> {
  $$PeersTableAnnotationComposer({
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

  GeneratedColumn<String> get deviceType => $composableBuilder(
      column: $table.deviceType, builder: (column) => column);

  GeneratedColumn<String> get os =>
      $composableBuilder(column: $table.os, builder: (column) => column);

  GeneratedColumn<String> get icon =>
      $composableBuilder(column: $table.icon, builder: (column) => column);

  GeneratedColumn<Uint8List> get avatar =>
      $composableBuilder(column: $table.avatar, builder: (column) => column);

  GeneratedColumn<String> get lastIp =>
      $composableBuilder(column: $table.lastIp, builder: (column) => column);

  GeneratedColumn<int> get lastSeen =>
      $composableBuilder(column: $table.lastSeen, builder: (column) => column);

  GeneratedColumn<bool> get isTrusted =>
      $composableBuilder(column: $table.isTrusted, builder: (column) => column);
}

class $$PeersTableTableManager extends RootTableManager<
    _$AppDatabase,
    $PeersTable,
    PeerRow,
    $$PeersTableFilterComposer,
    $$PeersTableOrderingComposer,
    $$PeersTableAnnotationComposer,
    $$PeersTableCreateCompanionBuilder,
    $$PeersTableUpdateCompanionBuilder,
    (PeerRow, BaseReferences<_$AppDatabase, $PeersTable, PeerRow>),
    PeerRow,
    PrefetchHooks Function()> {
  $$PeersTableTableManager(_$AppDatabase db, $PeersTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PeersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PeersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PeersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<String> deviceType = const Value.absent(),
            Value<String?> os = const Value.absent(),
            Value<String?> icon = const Value.absent(),
            Value<Uint8List?> avatar = const Value.absent(),
            Value<String?> lastIp = const Value.absent(),
            Value<int?> lastSeen = const Value.absent(),
            Value<bool> isTrusted = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              PeersCompanion(
            id: id,
            name: name,
            deviceType: deviceType,
            os: os,
            icon: icon,
            avatar: avatar,
            lastIp: lastIp,
            lastSeen: lastSeen,
            isTrusted: isTrusted,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String name,
            required String deviceType,
            Value<String?> os = const Value.absent(),
            Value<String?> icon = const Value.absent(),
            Value<Uint8List?> avatar = const Value.absent(),
            Value<String?> lastIp = const Value.absent(),
            Value<int?> lastSeen = const Value.absent(),
            Value<bool> isTrusted = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              PeersCompanion.insert(
            id: id,
            name: name,
            deviceType: deviceType,
            os: os,
            icon: icon,
            avatar: avatar,
            lastIp: lastIp,
            lastSeen: lastSeen,
            isTrusted: isTrusted,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$PeersTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $PeersTable,
    PeerRow,
    $$PeersTableFilterComposer,
    $$PeersTableOrderingComposer,
    $$PeersTableAnnotationComposer,
    $$PeersTableCreateCompanionBuilder,
    $$PeersTableUpdateCompanionBuilder,
    (PeerRow, BaseReferences<_$AppDatabase, $PeersTable, PeerRow>),
    PeerRow,
    PrefetchHooks Function()>;
typedef $$ConversationsTableCreateCompanionBuilder = ConversationsCompanion
    Function({
  required String id,
  required String peerId,
  required int createdAt,
  Value<int?> lastMsgAt,
  Value<int> unreadCount,
  Value<String?> draft,
  Value<int> rowid,
});
typedef $$ConversationsTableUpdateCompanionBuilder = ConversationsCompanion
    Function({
  Value<String> id,
  Value<String> peerId,
  Value<int> createdAt,
  Value<int?> lastMsgAt,
  Value<int> unreadCount,
  Value<String?> draft,
  Value<int> rowid,
});

final class $$ConversationsTableReferences extends BaseReferences<_$AppDatabase,
    $ConversationsTable, ConversationRow> {
  $$ConversationsTableReferences(
      super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$MessagesTable, List<MessageRow>>
      _messagesRefsTable(_$AppDatabase db) =>
          MultiTypedResultKey.fromTable(db.messages,
              aliasName: $_aliasNameGenerator(
                  db.conversations.id, db.messages.conversationId));

  $$MessagesTableProcessedTableManager get messagesRefs {
    final manager = $$MessagesTableTableManager($_db, $_db.messages).filter(
        (f) => f.conversationId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_messagesRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }
}

class $$ConversationsTableFilterComposer
    extends Composer<_$AppDatabase, $ConversationsTable> {
  $$ConversationsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get peerId => $composableBuilder(
      column: $table.peerId, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get lastMsgAt => $composableBuilder(
      column: $table.lastMsgAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get unreadCount => $composableBuilder(
      column: $table.unreadCount, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get draft => $composableBuilder(
      column: $table.draft, builder: (column) => ColumnFilters(column));

  Expression<bool> messagesRefs(
      Expression<bool> Function($$MessagesTableFilterComposer f) f) {
    final $$MessagesTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.messages,
        getReferencedColumn: (t) => t.conversationId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$MessagesTableFilterComposer(
              $db: $db,
              $table: $db.messages,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$ConversationsTableOrderingComposer
    extends Composer<_$AppDatabase, $ConversationsTable> {
  $$ConversationsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get peerId => $composableBuilder(
      column: $table.peerId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get lastMsgAt => $composableBuilder(
      column: $table.lastMsgAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get unreadCount => $composableBuilder(
      column: $table.unreadCount, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get draft => $composableBuilder(
      column: $table.draft, builder: (column) => ColumnOrderings(column));
}

class $$ConversationsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ConversationsTable> {
  $$ConversationsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get peerId =>
      $composableBuilder(column: $table.peerId, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get lastMsgAt =>
      $composableBuilder(column: $table.lastMsgAt, builder: (column) => column);

  GeneratedColumn<int> get unreadCount => $composableBuilder(
      column: $table.unreadCount, builder: (column) => column);

  GeneratedColumn<String> get draft =>
      $composableBuilder(column: $table.draft, builder: (column) => column);

  Expression<T> messagesRefs<T extends Object>(
      Expression<T> Function($$MessagesTableAnnotationComposer a) f) {
    final $$MessagesTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.messages,
        getReferencedColumn: (t) => t.conversationId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$MessagesTableAnnotationComposer(
              $db: $db,
              $table: $db.messages,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$ConversationsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $ConversationsTable,
    ConversationRow,
    $$ConversationsTableFilterComposer,
    $$ConversationsTableOrderingComposer,
    $$ConversationsTableAnnotationComposer,
    $$ConversationsTableCreateCompanionBuilder,
    $$ConversationsTableUpdateCompanionBuilder,
    (ConversationRow, $$ConversationsTableReferences),
    ConversationRow,
    PrefetchHooks Function({bool messagesRefs})> {
  $$ConversationsTableTableManager(_$AppDatabase db, $ConversationsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ConversationsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ConversationsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ConversationsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> peerId = const Value.absent(),
            Value<int> createdAt = const Value.absent(),
            Value<int?> lastMsgAt = const Value.absent(),
            Value<int> unreadCount = const Value.absent(),
            Value<String?> draft = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              ConversationsCompanion(
            id: id,
            peerId: peerId,
            createdAt: createdAt,
            lastMsgAt: lastMsgAt,
            unreadCount: unreadCount,
            draft: draft,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String peerId,
            required int createdAt,
            Value<int?> lastMsgAt = const Value.absent(),
            Value<int> unreadCount = const Value.absent(),
            Value<String?> draft = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              ConversationsCompanion.insert(
            id: id,
            peerId: peerId,
            createdAt: createdAt,
            lastMsgAt: lastMsgAt,
            unreadCount: unreadCount,
            draft: draft,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$ConversationsTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({messagesRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (messagesRefs) db.messages],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (messagesRefs)
                    await $_getPrefetchedData<ConversationRow,
                            $ConversationsTable, MessageRow>(
                        currentTable: table,
                        referencedTable: $$ConversationsTableReferences
                            ._messagesRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$ConversationsTableReferences(db, table, p0)
                                .messagesRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.conversationId == item.id),
                        typedResults: items)
                ];
              },
            );
          },
        ));
}

typedef $$ConversationsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $ConversationsTable,
    ConversationRow,
    $$ConversationsTableFilterComposer,
    $$ConversationsTableOrderingComposer,
    $$ConversationsTableAnnotationComposer,
    $$ConversationsTableCreateCompanionBuilder,
    $$ConversationsTableUpdateCompanionBuilder,
    (ConversationRow, $$ConversationsTableReferences),
    ConversationRow,
    PrefetchHooks Function({bool messagesRefs})>;
typedef $$MessagesTableCreateCompanionBuilder = MessagesCompanion Function({
  required String id,
  required String conversationId,
  required String peerId,
  required String direction,
  required String type,
  Value<String?> body,
  required String status,
  required int createdAt,
  Value<int?> deliveredAt,
  Value<int> retryCount,
  Value<int> rowid,
});
typedef $$MessagesTableUpdateCompanionBuilder = MessagesCompanion Function({
  Value<String> id,
  Value<String> conversationId,
  Value<String> peerId,
  Value<String> direction,
  Value<String> type,
  Value<String?> body,
  Value<String> status,
  Value<int> createdAt,
  Value<int?> deliveredAt,
  Value<int> retryCount,
  Value<int> rowid,
});

final class $$MessagesTableReferences
    extends BaseReferences<_$AppDatabase, $MessagesTable, MessageRow> {
  $$MessagesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $ConversationsTable _conversationIdTable(_$AppDatabase db) =>
      db.conversations.createAlias($_aliasNameGenerator(
          db.messages.conversationId, db.conversations.id));

  $$ConversationsTableProcessedTableManager get conversationId {
    final $_column = $_itemColumn<String>('conversation_id')!;

    final manager = $$ConversationsTableTableManager($_db, $_db.conversations)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_conversationIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }

  static MultiTypedResultKey<$AttachmentsTable, List<AttachmentRow>>
      _attachmentsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
          db.attachments,
          aliasName:
              $_aliasNameGenerator(db.messages.id, db.attachments.messageId));

  $$AttachmentsTableProcessedTableManager get attachmentsRefs {
    final manager = $$AttachmentsTableTableManager($_db, $_db.attachments)
        .filter((f) => f.messageId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_attachmentsRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }

  static MultiTypedResultKey<$TransfersTable, List<TransferRow>>
      _transfersRefsTable(_$AppDatabase db) =>
          MultiTypedResultKey.fromTable(db.transfers,
              aliasName:
                  $_aliasNameGenerator(db.messages.id, db.transfers.messageId));

  $$TransfersTableProcessedTableManager get transfersRefs {
    final manager = $$TransfersTableTableManager($_db, $_db.transfers)
        .filter((f) => f.messageId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_transfersRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }
}

class $$MessagesTableFilterComposer
    extends Composer<_$AppDatabase, $MessagesTable> {
  $$MessagesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get peerId => $composableBuilder(
      column: $table.peerId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get direction => $composableBuilder(
      column: $table.direction, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get type => $composableBuilder(
      column: $table.type, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get body => $composableBuilder(
      column: $table.body, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get status => $composableBuilder(
      column: $table.status, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get deliveredAt => $composableBuilder(
      column: $table.deliveredAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get retryCount => $composableBuilder(
      column: $table.retryCount, builder: (column) => ColumnFilters(column));

  $$ConversationsTableFilterComposer get conversationId {
    final $$ConversationsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.conversationId,
        referencedTable: $db.conversations,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$ConversationsTableFilterComposer(
              $db: $db,
              $table: $db.conversations,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  Expression<bool> attachmentsRefs(
      Expression<bool> Function($$AttachmentsTableFilterComposer f) f) {
    final $$AttachmentsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.attachments,
        getReferencedColumn: (t) => t.messageId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$AttachmentsTableFilterComposer(
              $db: $db,
              $table: $db.attachments,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<bool> transfersRefs(
      Expression<bool> Function($$TransfersTableFilterComposer f) f) {
    final $$TransfersTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.transfers,
        getReferencedColumn: (t) => t.messageId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$TransfersTableFilterComposer(
              $db: $db,
              $table: $db.transfers,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$MessagesTableOrderingComposer
    extends Composer<_$AppDatabase, $MessagesTable> {
  $$MessagesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get peerId => $composableBuilder(
      column: $table.peerId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get direction => $composableBuilder(
      column: $table.direction, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get type => $composableBuilder(
      column: $table.type, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get body => $composableBuilder(
      column: $table.body, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get status => $composableBuilder(
      column: $table.status, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get deliveredAt => $composableBuilder(
      column: $table.deliveredAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get retryCount => $composableBuilder(
      column: $table.retryCount, builder: (column) => ColumnOrderings(column));

  $$ConversationsTableOrderingComposer get conversationId {
    final $$ConversationsTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.conversationId,
        referencedTable: $db.conversations,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$ConversationsTableOrderingComposer(
              $db: $db,
              $table: $db.conversations,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$MessagesTableAnnotationComposer
    extends Composer<_$AppDatabase, $MessagesTable> {
  $$MessagesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get peerId =>
      $composableBuilder(column: $table.peerId, builder: (column) => column);

  GeneratedColumn<String> get direction =>
      $composableBuilder(column: $table.direction, builder: (column) => column);

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<String> get body =>
      $composableBuilder(column: $table.body, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get deliveredAt => $composableBuilder(
      column: $table.deliveredAt, builder: (column) => column);

  GeneratedColumn<int> get retryCount => $composableBuilder(
      column: $table.retryCount, builder: (column) => column);

  $$ConversationsTableAnnotationComposer get conversationId {
    final $$ConversationsTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.conversationId,
        referencedTable: $db.conversations,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$ConversationsTableAnnotationComposer(
              $db: $db,
              $table: $db.conversations,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  Expression<T> attachmentsRefs<T extends Object>(
      Expression<T> Function($$AttachmentsTableAnnotationComposer a) f) {
    final $$AttachmentsTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.attachments,
        getReferencedColumn: (t) => t.messageId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$AttachmentsTableAnnotationComposer(
              $db: $db,
              $table: $db.attachments,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<T> transfersRefs<T extends Object>(
      Expression<T> Function($$TransfersTableAnnotationComposer a) f) {
    final $$TransfersTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.transfers,
        getReferencedColumn: (t) => t.messageId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$TransfersTableAnnotationComposer(
              $db: $db,
              $table: $db.transfers,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$MessagesTableTableManager extends RootTableManager<
    _$AppDatabase,
    $MessagesTable,
    MessageRow,
    $$MessagesTableFilterComposer,
    $$MessagesTableOrderingComposer,
    $$MessagesTableAnnotationComposer,
    $$MessagesTableCreateCompanionBuilder,
    $$MessagesTableUpdateCompanionBuilder,
    (MessageRow, $$MessagesTableReferences),
    MessageRow,
    PrefetchHooks Function(
        {bool conversationId, bool attachmentsRefs, bool transfersRefs})> {
  $$MessagesTableTableManager(_$AppDatabase db, $MessagesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MessagesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MessagesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MessagesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> conversationId = const Value.absent(),
            Value<String> peerId = const Value.absent(),
            Value<String> direction = const Value.absent(),
            Value<String> type = const Value.absent(),
            Value<String?> body = const Value.absent(),
            Value<String> status = const Value.absent(),
            Value<int> createdAt = const Value.absent(),
            Value<int?> deliveredAt = const Value.absent(),
            Value<int> retryCount = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              MessagesCompanion(
            id: id,
            conversationId: conversationId,
            peerId: peerId,
            direction: direction,
            type: type,
            body: body,
            status: status,
            createdAt: createdAt,
            deliveredAt: deliveredAt,
            retryCount: retryCount,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String conversationId,
            required String peerId,
            required String direction,
            required String type,
            Value<String?> body = const Value.absent(),
            required String status,
            required int createdAt,
            Value<int?> deliveredAt = const Value.absent(),
            Value<int> retryCount = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              MessagesCompanion.insert(
            id: id,
            conversationId: conversationId,
            peerId: peerId,
            direction: direction,
            type: type,
            body: body,
            status: status,
            createdAt: createdAt,
            deliveredAt: deliveredAt,
            retryCount: retryCount,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) =>
                  (e.readTable(table), $$MessagesTableReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: (
              {conversationId = false,
              attachmentsRefs = false,
              transfersRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (attachmentsRefs) db.attachments,
                if (transfersRefs) db.transfers
              ],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (conversationId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.conversationId,
                    referencedTable:
                        $$MessagesTableReferences._conversationIdTable(db),
                    referencedColumn:
                        $$MessagesTableReferences._conversationIdTable(db).id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [
                  if (attachmentsRefs)
                    await $_getPrefetchedData<MessageRow, $MessagesTable,
                            AttachmentRow>(
                        currentTable: table,
                        referencedTable:
                            $$MessagesTableReferences._attachmentsRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$MessagesTableReferences(db, table, p0)
                                .attachmentsRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.messageId == item.id),
                        typedResults: items),
                  if (transfersRefs)
                    await $_getPrefetchedData<MessageRow, $MessagesTable,
                            TransferRow>(
                        currentTable: table,
                        referencedTable:
                            $$MessagesTableReferences._transfersRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$MessagesTableReferences(db, table, p0)
                                .transfersRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.messageId == item.id),
                        typedResults: items)
                ];
              },
            );
          },
        ));
}

typedef $$MessagesTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $MessagesTable,
    MessageRow,
    $$MessagesTableFilterComposer,
    $$MessagesTableOrderingComposer,
    $$MessagesTableAnnotationComposer,
    $$MessagesTableCreateCompanionBuilder,
    $$MessagesTableUpdateCompanionBuilder,
    (MessageRow, $$MessagesTableReferences),
    MessageRow,
    PrefetchHooks Function(
        {bool conversationId, bool attachmentsRefs, bool transfersRefs})>;
typedef $$AttachmentsTableCreateCompanionBuilder = AttachmentsCompanion
    Function({
  required String id,
  required String messageId,
  required String fileName,
  Value<String?> relPath,
  required int size,
  Value<String?> mime,
  Value<String?> localPath,
  Value<String?> thumbPath,
  Value<String?> sha256,
  required String state,
  Value<int> transferred,
  Value<int> rowid,
});
typedef $$AttachmentsTableUpdateCompanionBuilder = AttachmentsCompanion
    Function({
  Value<String> id,
  Value<String> messageId,
  Value<String> fileName,
  Value<String?> relPath,
  Value<int> size,
  Value<String?> mime,
  Value<String?> localPath,
  Value<String?> thumbPath,
  Value<String?> sha256,
  Value<String> state,
  Value<int> transferred,
  Value<int> rowid,
});

final class $$AttachmentsTableReferences
    extends BaseReferences<_$AppDatabase, $AttachmentsTable, AttachmentRow> {
  $$AttachmentsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $MessagesTable _messageIdTable(_$AppDatabase db) =>
      db.messages.createAlias(
          $_aliasNameGenerator(db.attachments.messageId, db.messages.id));

  $$MessagesTableProcessedTableManager get messageId {
    final $_column = $_itemColumn<String>('message_id')!;

    final manager = $$MessagesTableTableManager($_db, $_db.messages)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_messageIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }

  static MultiTypedResultKey<$TransfersTable, List<TransferRow>>
      _transfersRefsTable(_$AppDatabase db) =>
          MultiTypedResultKey.fromTable(db.transfers,
              aliasName: $_aliasNameGenerator(
                  db.attachments.id, db.transfers.attachmentId));

  $$TransfersTableProcessedTableManager get transfersRefs {
    final manager = $$TransfersTableTableManager($_db, $_db.transfers).filter(
        (f) => f.attachmentId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_transfersRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }
}

class $$AttachmentsTableFilterComposer
    extends Composer<_$AppDatabase, $AttachmentsTable> {
  $$AttachmentsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get fileName => $composableBuilder(
      column: $table.fileName, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get relPath => $composableBuilder(
      column: $table.relPath, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get size => $composableBuilder(
      column: $table.size, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get mime => $composableBuilder(
      column: $table.mime, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get localPath => $composableBuilder(
      column: $table.localPath, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get thumbPath => $composableBuilder(
      column: $table.thumbPath, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get sha256 => $composableBuilder(
      column: $table.sha256, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get state => $composableBuilder(
      column: $table.state, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get transferred => $composableBuilder(
      column: $table.transferred, builder: (column) => ColumnFilters(column));

  $$MessagesTableFilterComposer get messageId {
    final $$MessagesTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.messageId,
        referencedTable: $db.messages,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$MessagesTableFilterComposer(
              $db: $db,
              $table: $db.messages,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  Expression<bool> transfersRefs(
      Expression<bool> Function($$TransfersTableFilterComposer f) f) {
    final $$TransfersTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.transfers,
        getReferencedColumn: (t) => t.attachmentId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$TransfersTableFilterComposer(
              $db: $db,
              $table: $db.transfers,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$AttachmentsTableOrderingComposer
    extends Composer<_$AppDatabase, $AttachmentsTable> {
  $$AttachmentsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get fileName => $composableBuilder(
      column: $table.fileName, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get relPath => $composableBuilder(
      column: $table.relPath, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get size => $composableBuilder(
      column: $table.size, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get mime => $composableBuilder(
      column: $table.mime, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get localPath => $composableBuilder(
      column: $table.localPath, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get thumbPath => $composableBuilder(
      column: $table.thumbPath, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get sha256 => $composableBuilder(
      column: $table.sha256, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get state => $composableBuilder(
      column: $table.state, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get transferred => $composableBuilder(
      column: $table.transferred, builder: (column) => ColumnOrderings(column));

  $$MessagesTableOrderingComposer get messageId {
    final $$MessagesTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.messageId,
        referencedTable: $db.messages,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$MessagesTableOrderingComposer(
              $db: $db,
              $table: $db.messages,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$AttachmentsTableAnnotationComposer
    extends Composer<_$AppDatabase, $AttachmentsTable> {
  $$AttachmentsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get fileName =>
      $composableBuilder(column: $table.fileName, builder: (column) => column);

  GeneratedColumn<String> get relPath =>
      $composableBuilder(column: $table.relPath, builder: (column) => column);

  GeneratedColumn<int> get size =>
      $composableBuilder(column: $table.size, builder: (column) => column);

  GeneratedColumn<String> get mime =>
      $composableBuilder(column: $table.mime, builder: (column) => column);

  GeneratedColumn<String> get localPath =>
      $composableBuilder(column: $table.localPath, builder: (column) => column);

  GeneratedColumn<String> get thumbPath =>
      $composableBuilder(column: $table.thumbPath, builder: (column) => column);

  GeneratedColumn<String> get sha256 =>
      $composableBuilder(column: $table.sha256, builder: (column) => column);

  GeneratedColumn<String> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);

  GeneratedColumn<int> get transferred => $composableBuilder(
      column: $table.transferred, builder: (column) => column);

  $$MessagesTableAnnotationComposer get messageId {
    final $$MessagesTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.messageId,
        referencedTable: $db.messages,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$MessagesTableAnnotationComposer(
              $db: $db,
              $table: $db.messages,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  Expression<T> transfersRefs<T extends Object>(
      Expression<T> Function($$TransfersTableAnnotationComposer a) f) {
    final $$TransfersTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.transfers,
        getReferencedColumn: (t) => t.attachmentId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$TransfersTableAnnotationComposer(
              $db: $db,
              $table: $db.transfers,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$AttachmentsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $AttachmentsTable,
    AttachmentRow,
    $$AttachmentsTableFilterComposer,
    $$AttachmentsTableOrderingComposer,
    $$AttachmentsTableAnnotationComposer,
    $$AttachmentsTableCreateCompanionBuilder,
    $$AttachmentsTableUpdateCompanionBuilder,
    (AttachmentRow, $$AttachmentsTableReferences),
    AttachmentRow,
    PrefetchHooks Function({bool messageId, bool transfersRefs})> {
  $$AttachmentsTableTableManager(_$AppDatabase db, $AttachmentsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AttachmentsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AttachmentsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AttachmentsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> messageId = const Value.absent(),
            Value<String> fileName = const Value.absent(),
            Value<String?> relPath = const Value.absent(),
            Value<int> size = const Value.absent(),
            Value<String?> mime = const Value.absent(),
            Value<String?> localPath = const Value.absent(),
            Value<String?> thumbPath = const Value.absent(),
            Value<String?> sha256 = const Value.absent(),
            Value<String> state = const Value.absent(),
            Value<int> transferred = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              AttachmentsCompanion(
            id: id,
            messageId: messageId,
            fileName: fileName,
            relPath: relPath,
            size: size,
            mime: mime,
            localPath: localPath,
            thumbPath: thumbPath,
            sha256: sha256,
            state: state,
            transferred: transferred,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String messageId,
            required String fileName,
            Value<String?> relPath = const Value.absent(),
            required int size,
            Value<String?> mime = const Value.absent(),
            Value<String?> localPath = const Value.absent(),
            Value<String?> thumbPath = const Value.absent(),
            Value<String?> sha256 = const Value.absent(),
            required String state,
            Value<int> transferred = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              AttachmentsCompanion.insert(
            id: id,
            messageId: messageId,
            fileName: fileName,
            relPath: relPath,
            size: size,
            mime: mime,
            localPath: localPath,
            thumbPath: thumbPath,
            sha256: sha256,
            state: state,
            transferred: transferred,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$AttachmentsTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({messageId = false, transfersRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (transfersRefs) db.transfers],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (messageId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.messageId,
                    referencedTable:
                        $$AttachmentsTableReferences._messageIdTable(db),
                    referencedColumn:
                        $$AttachmentsTableReferences._messageIdTable(db).id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [
                  if (transfersRefs)
                    await $_getPrefetchedData<AttachmentRow, $AttachmentsTable,
                            TransferRow>(
                        currentTable: table,
                        referencedTable: $$AttachmentsTableReferences
                            ._transfersRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$AttachmentsTableReferences(db, table, p0)
                                .transfersRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.attachmentId == item.id),
                        typedResults: items)
                ];
              },
            );
          },
        ));
}

typedef $$AttachmentsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $AttachmentsTable,
    AttachmentRow,
    $$AttachmentsTableFilterComposer,
    $$AttachmentsTableOrderingComposer,
    $$AttachmentsTableAnnotationComposer,
    $$AttachmentsTableCreateCompanionBuilder,
    $$AttachmentsTableUpdateCompanionBuilder,
    (AttachmentRow, $$AttachmentsTableReferences),
    AttachmentRow,
    PrefetchHooks Function({bool messageId, bool transfersRefs})>;
typedef $$TransfersTableCreateCompanionBuilder = TransfersCompanion Function({
  required String id,
  Value<String?> messageId,
  Value<String?> attachmentId,
  required String peerId,
  required String direction,
  required String state,
  Value<int> bytesDone,
  required int bytesTotal,
  Value<String?> tempPath,
  required int updatedAt,
  Value<int> rowid,
});
typedef $$TransfersTableUpdateCompanionBuilder = TransfersCompanion Function({
  Value<String> id,
  Value<String?> messageId,
  Value<String?> attachmentId,
  Value<String> peerId,
  Value<String> direction,
  Value<String> state,
  Value<int> bytesDone,
  Value<int> bytesTotal,
  Value<String?> tempPath,
  Value<int> updatedAt,
  Value<int> rowid,
});

final class $$TransfersTableReferences
    extends BaseReferences<_$AppDatabase, $TransfersTable, TransferRow> {
  $$TransfersTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $MessagesTable _messageIdTable(_$AppDatabase db) =>
      db.messages.createAlias(
          $_aliasNameGenerator(db.transfers.messageId, db.messages.id));

  $$MessagesTableProcessedTableManager? get messageId {
    final $_column = $_itemColumn<String>('message_id');
    if ($_column == null) return null;
    final manager = $$MessagesTableTableManager($_db, $_db.messages)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_messageIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }

  static $AttachmentsTable _attachmentIdTable(_$AppDatabase db) =>
      db.attachments.createAlias(
          $_aliasNameGenerator(db.transfers.attachmentId, db.attachments.id));

  $$AttachmentsTableProcessedTableManager? get attachmentId {
    final $_column = $_itemColumn<String>('attachment_id');
    if ($_column == null) return null;
    final manager = $$AttachmentsTableTableManager($_db, $_db.attachments)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_attachmentIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$TransfersTableFilterComposer
    extends Composer<_$AppDatabase, $TransfersTable> {
  $$TransfersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get peerId => $composableBuilder(
      column: $table.peerId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get direction => $composableBuilder(
      column: $table.direction, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get state => $composableBuilder(
      column: $table.state, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get bytesDone => $composableBuilder(
      column: $table.bytesDone, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get bytesTotal => $composableBuilder(
      column: $table.bytesTotal, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get tempPath => $composableBuilder(
      column: $table.tempPath, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));

  $$MessagesTableFilterComposer get messageId {
    final $$MessagesTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.messageId,
        referencedTable: $db.messages,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$MessagesTableFilterComposer(
              $db: $db,
              $table: $db.messages,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$AttachmentsTableFilterComposer get attachmentId {
    final $$AttachmentsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.attachmentId,
        referencedTable: $db.attachments,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$AttachmentsTableFilterComposer(
              $db: $db,
              $table: $db.attachments,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$TransfersTableOrderingComposer
    extends Composer<_$AppDatabase, $TransfersTable> {
  $$TransfersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get peerId => $composableBuilder(
      column: $table.peerId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get direction => $composableBuilder(
      column: $table.direction, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get state => $composableBuilder(
      column: $table.state, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get bytesDone => $composableBuilder(
      column: $table.bytesDone, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get bytesTotal => $composableBuilder(
      column: $table.bytesTotal, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get tempPath => $composableBuilder(
      column: $table.tempPath, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));

  $$MessagesTableOrderingComposer get messageId {
    final $$MessagesTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.messageId,
        referencedTable: $db.messages,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$MessagesTableOrderingComposer(
              $db: $db,
              $table: $db.messages,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$AttachmentsTableOrderingComposer get attachmentId {
    final $$AttachmentsTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.attachmentId,
        referencedTable: $db.attachments,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$AttachmentsTableOrderingComposer(
              $db: $db,
              $table: $db.attachments,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$TransfersTableAnnotationComposer
    extends Composer<_$AppDatabase, $TransfersTable> {
  $$TransfersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get peerId =>
      $composableBuilder(column: $table.peerId, builder: (column) => column);

  GeneratedColumn<String> get direction =>
      $composableBuilder(column: $table.direction, builder: (column) => column);

  GeneratedColumn<String> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);

  GeneratedColumn<int> get bytesDone =>
      $composableBuilder(column: $table.bytesDone, builder: (column) => column);

  GeneratedColumn<int> get bytesTotal => $composableBuilder(
      column: $table.bytesTotal, builder: (column) => column);

  GeneratedColumn<String> get tempPath =>
      $composableBuilder(column: $table.tempPath, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  $$MessagesTableAnnotationComposer get messageId {
    final $$MessagesTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.messageId,
        referencedTable: $db.messages,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$MessagesTableAnnotationComposer(
              $db: $db,
              $table: $db.messages,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$AttachmentsTableAnnotationComposer get attachmentId {
    final $$AttachmentsTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.attachmentId,
        referencedTable: $db.attachments,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$AttachmentsTableAnnotationComposer(
              $db: $db,
              $table: $db.attachments,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$TransfersTableTableManager extends RootTableManager<
    _$AppDatabase,
    $TransfersTable,
    TransferRow,
    $$TransfersTableFilterComposer,
    $$TransfersTableOrderingComposer,
    $$TransfersTableAnnotationComposer,
    $$TransfersTableCreateCompanionBuilder,
    $$TransfersTableUpdateCompanionBuilder,
    (TransferRow, $$TransfersTableReferences),
    TransferRow,
    PrefetchHooks Function({bool messageId, bool attachmentId})> {
  $$TransfersTableTableManager(_$AppDatabase db, $TransfersTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TransfersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TransfersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TransfersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String?> messageId = const Value.absent(),
            Value<String?> attachmentId = const Value.absent(),
            Value<String> peerId = const Value.absent(),
            Value<String> direction = const Value.absent(),
            Value<String> state = const Value.absent(),
            Value<int> bytesDone = const Value.absent(),
            Value<int> bytesTotal = const Value.absent(),
            Value<String?> tempPath = const Value.absent(),
            Value<int> updatedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              TransfersCompanion(
            id: id,
            messageId: messageId,
            attachmentId: attachmentId,
            peerId: peerId,
            direction: direction,
            state: state,
            bytesDone: bytesDone,
            bytesTotal: bytesTotal,
            tempPath: tempPath,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            Value<String?> messageId = const Value.absent(),
            Value<String?> attachmentId = const Value.absent(),
            required String peerId,
            required String direction,
            required String state,
            Value<int> bytesDone = const Value.absent(),
            required int bytesTotal,
            Value<String?> tempPath = const Value.absent(),
            required int updatedAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              TransfersCompanion.insert(
            id: id,
            messageId: messageId,
            attachmentId: attachmentId,
            peerId: peerId,
            direction: direction,
            state: state,
            bytesDone: bytesDone,
            bytesTotal: bytesTotal,
            tempPath: tempPath,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$TransfersTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({messageId = false, attachmentId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (messageId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.messageId,
                    referencedTable:
                        $$TransfersTableReferences._messageIdTable(db),
                    referencedColumn:
                        $$TransfersTableReferences._messageIdTable(db).id,
                  ) as T;
                }
                if (attachmentId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.attachmentId,
                    referencedTable:
                        $$TransfersTableReferences._attachmentIdTable(db),
                    referencedColumn:
                        $$TransfersTableReferences._attachmentIdTable(db).id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$TransfersTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $TransfersTable,
    TransferRow,
    $$TransfersTableFilterComposer,
    $$TransfersTableOrderingComposer,
    $$TransfersTableAnnotationComposer,
    $$TransfersTableCreateCompanionBuilder,
    $$TransfersTableUpdateCompanionBuilder,
    (TransferRow, $$TransfersTableReferences),
    TransferRow,
    PrefetchHooks Function({bool messageId, bool attachmentId})>;
typedef $$SettingsTableCreateCompanionBuilder = SettingsCompanion Function({
  required String key,
  required String value,
  Value<int> rowid,
});
typedef $$SettingsTableUpdateCompanionBuilder = SettingsCompanion Function({
  Value<String> key,
  Value<String> value,
  Value<int> rowid,
});

class $$SettingsTableFilterComposer
    extends Composer<_$AppDatabase, $SettingsTable> {
  $$SettingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get value => $composableBuilder(
      column: $table.value, builder: (column) => ColumnFilters(column));
}

class $$SettingsTableOrderingComposer
    extends Composer<_$AppDatabase, $SettingsTable> {
  $$SettingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get value => $composableBuilder(
      column: $table.value, builder: (column) => ColumnOrderings(column));
}

class $$SettingsTableAnnotationComposer
    extends Composer<_$AppDatabase, $SettingsTable> {
  $$SettingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$SettingsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $SettingsTable,
    SettingRow,
    $$SettingsTableFilterComposer,
    $$SettingsTableOrderingComposer,
    $$SettingsTableAnnotationComposer,
    $$SettingsTableCreateCompanionBuilder,
    $$SettingsTableUpdateCompanionBuilder,
    (SettingRow, BaseReferences<_$AppDatabase, $SettingsTable, SettingRow>),
    SettingRow,
    PrefetchHooks Function()> {
  $$SettingsTableTableManager(_$AppDatabase db, $SettingsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SettingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SettingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SettingsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> key = const Value.absent(),
            Value<String> value = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              SettingsCompanion(
            key: key,
            value: value,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String key,
            required String value,
            Value<int> rowid = const Value.absent(),
          }) =>
              SettingsCompanion.insert(
            key: key,
            value: value,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$SettingsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $SettingsTable,
    SettingRow,
    $$SettingsTableFilterComposer,
    $$SettingsTableOrderingComposer,
    $$SettingsTableAnnotationComposer,
    $$SettingsTableCreateCompanionBuilder,
    $$SettingsTableUpdateCompanionBuilder,
    (SettingRow, BaseReferences<_$AppDatabase, $SettingsTable, SettingRow>),
    SettingRow,
    PrefetchHooks Function()>;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$PeersTableTableManager get peers =>
      $$PeersTableTableManager(_db, _db.peers);
  $$ConversationsTableTableManager get conversations =>
      $$ConversationsTableTableManager(_db, _db.conversations);
  $$MessagesTableTableManager get messages =>
      $$MessagesTableTableManager(_db, _db.messages);
  $$AttachmentsTableTableManager get attachments =>
      $$AttachmentsTableTableManager(_db, _db.attachments);
  $$TransfersTableTableManager get transfers =>
      $$TransfersTableTableManager(_db, _db.transfers);
  $$SettingsTableTableManager get settings =>
      $$SettingsTableTableManager(_db, _db.settings);
}
