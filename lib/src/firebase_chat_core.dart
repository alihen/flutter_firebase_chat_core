import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'util.dart';

/// Provides access to Firebase chat data. Singleton, use
/// FirebaseChatCore.instance to aceess methods.
class FirebaseChatCore {
  FirebaseChatCore._privateConstructor() {
    FirebaseAuth.instance.authStateChanges().listen((User? user) {
      firebaseUser = user;
    });
  }

  /// Current logged in user in Firebase. Does not update automatically.
  /// Use [FirebaseAuth.authStateChanges] to listen to the state changes.
  User? firebaseUser = FirebaseAuth.instance.currentUser;

  /// Singleton instance
  static final FirebaseChatCore instance =
      FirebaseChatCore._privateConstructor();

  /// Creates a chat group room
  Future<types.Room> createGroupRoom({
    String? imageUrl,
    required String name,
    required List<types.User> users,
    Map<String, dynamic>? metadata,
  }) async {
    if (firebaseUser == null) return Future.error('User does not exist');

    final currentUser = await fetchUser(firebaseUser!.uid);
    final roomUsers = [currentUser] + users;

    final room = await FirebaseFirestore.instance.collection('rooms').add({
      'imageUrl': imageUrl,
      'name': name,
      'type': 'group',
      'userIds': roomUsers.map((u) => u.id).toList(),
      'metadata': metadata
    });

    return types.Room(
      id: room.id,
      imageUrl: imageUrl,
      name: name,
      type: types.RoomType.group,
      users: roomUsers,
      metadata: metadata,
    );
  }

  /// Creates a normal room for 2 people
  Future<types.Room> createRoom(
    types.User otherUser,
    Map<String, dynamic>? metadata,
  ) async {
    if (firebaseUser == null) return Future.error('User does not exist');

    final query = await FirebaseFirestore.instance
        .collection('rooms')
        .where('userIds', arrayContains: firebaseUser!.uid)
        .get();

    final rooms = await processRoomsQuery(firebaseUser!, query);

    try {
      return rooms.firstWhere((room) {
        if (room.type == types.RoomType.group) return false;

        final userIds = room.users.map((u) => u.id);
        return userIds.contains(firebaseUser!.uid) &&
            userIds.contains(otherUser.id);
      });
    } catch (e) {
      // Do nothing if room does not exist
      // Create a new room instead
    }

    final currentUser = await fetchUser(firebaseUser!.uid);
    final users = [currentUser, otherUser];

    final room = await FirebaseFirestore.instance.collection('rooms').add({
      'imageUrl': null,
      'name': null,
      'type': 'direct',
      'userIds': users.map((u) => u.id).toList(),
      'metadata': metadata
    });

    return types.Room(
      id: room.id,
      type: types.RoomType.direct,
      users: users,
      metadata: metadata,
    );
  }

  /// Creates [types.User] in Firebase to store name and avatar used on
  /// rooms list
  Future<void> createUserInFirestore(types.User user) async {
    await FirebaseFirestore.instance.collection('users').doc(user.id).set({
      'avatarUrl': user.avatarUrl,
      'firstName': user.firstName,
      'lastName': user.lastName,
    });
  }

  /// Returns a stream of messages from Firebase for a given room
  Stream<List<types.Message>> messages(String roomId) {
    return FirebaseFirestore.instance
        .collection('rooms/$roomId/messages')
        .orderBy('timestamp', descending: true)
        .snapshots()
        .map(
      (snapshot) {
        return snapshot.docs.fold<List<types.Message>>(
          [],
          (previousValue, element) {
            final data = element.data();

            if (data != null) {
              data['id'] = element.id;
              data['timestamp'] = element['timestamp']?.seconds;
              return [...previousValue, types.Message.fromJson(data)];
            }

            return previousValue;
          },
        );
      },
    );
  }

  /// Returns a stream of rooms from Firebase. Only rooms where current
  /// logged in user exist are returned.
  Stream<List<types.Room>> rooms() {
    if (firebaseUser == null) return const Stream.empty();

    return FirebaseFirestore.instance
        .collection('rooms')
        .where('userIds', arrayContains: firebaseUser!.uid)
        .snapshots()
        .asyncMap((query) => processRoomsQuery(firebaseUser!, query));
  }

  void sendMessage(dynamic partialMessage, String roomId) async {
    if (firebaseUser == null) return;

    types.Message? message;

    if (partialMessage is types.PartialFile) {
      message = types.FileMessage.fromPartial(
        authorId: firebaseUser!.uid,
        id: '',
        partialFile: partialMessage,
      );
    } else if (partialMessage is types.PartialImage) {
      message = types.ImageMessage.fromPartial(
        authorId: firebaseUser!.uid,
        id: '',
        partialImage: partialMessage,
      );
    } else if (partialMessage is types.PartialText) {
      message = types.TextMessage.fromPartial(
        authorId: firebaseUser!.uid,
        id: '',
        partialText: partialMessage,
      );
    }

    if (message != null) {
      final messageMap = message.toJson();
      messageMap.removeWhere((key, value) => key == 'id');
      messageMap['timestamp'] = FieldValue.serverTimestamp();

      await FirebaseFirestore.instance
          .collection('rooms/$roomId/messages')
          .add(messageMap);
    }
  }

  void updateMessage(types.Message message, String roomId) async {
    if (firebaseUser == null) return;
    if (message.authorId != firebaseUser!.uid) return;

    final messageMap = message.toJson();
    messageMap.removeWhere((key, value) => key == 'id' || key == 'timestamp');

    await FirebaseFirestore.instance
        .collection('rooms/$roomId/messages')
        .doc(message.id)
        .update(messageMap);
  }

  /// Returns a stream of all users from Firebase
  Stream<List<types.User>> users() {
    if (firebaseUser == null) return const Stream.empty();
    return FirebaseFirestore.instance.collection('users').snapshots().map(
          (snapshot) => snapshot.docs.fold<List<types.User>>(
            [],
            (previousValue, element) {
              if (firebaseUser!.uid == element.id) return previousValue;

              return [...previousValue, processUserDocument(element)];
            },
          ),
        );
  }
}
