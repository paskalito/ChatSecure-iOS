//
//  OTRXMPPRoomManager.m
//  ChatSecure
//
//  Created by David Chiles on 10/9/15.
//  Copyright © 2015 Chris Ballinger. All rights reserved.
//

#import "OTRXMPPRoomManager.h"
@import XMPPFramework;
#import <ChatSecureCore/ChatSecureCore-Swift.h>
#import "OTRXMPPRoomYapStorage.h"
#import "OTRBuddy.h"
@import YapDatabase;
#import "OTRLog.h"

@interface OTRXMPPRoomManager () <XMPPMUCDelegate, XMPPRoomDelegate, XMPPStreamDelegate, OTRYapViewHandlerDelegateProtocol>

@property (nonatomic, strong) NSMutableDictionary *rooms;

@property (nonatomic, strong) XMPPMUC *mucModule;

@property (nonatomic, strong) OTRYapViewHandler *unsentMessagesViewHandler;

/** This dictionary has jid as the key and array of buddy unique Ids to invite once we've joined the room*/
@property (nonatomic, strong) NSMutableDictionary *inviteDictionary;

/** This dictionary is a temporary holding for setting a room subject. Once the room is created teh subject is set from this dictionary. */
@property (nonatomic, strong) NSMutableDictionary *tempRoomSubject;


@end

@implementation OTRXMPPRoomManager

- (instancetype)init {
    if (self = [super init]) {
        self.mucModule = [[XMPPMUC alloc] init];
        self.inviteDictionary = [[NSMutableDictionary alloc] init];
        self.tempRoomSubject = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (BOOL)activate:(XMPPStream *)aXmppStream
{
    BOOL result = [super activate:aXmppStream];
    [self.mucModule activate:aXmppStream];
    [self.mucModule addDelegate:self delegateQueue:moduleQueue];
    [multicastDelegate addDelegate:self delegateQueue:moduleQueue];
    self.unsentMessagesViewHandler = [[OTRYapViewHandler alloc] initWithDatabaseConnection:[OTRDatabaseManager sharedInstance].longLivedReadOnlyConnection
                                                            databaseChangeNotificationName:[DatabaseNotificationName LongLivedTransactionChanges]];
    self.unsentMessagesViewHandler.delegate = self;
    return result;
}

- (NSString *)joinRoom:(XMPPJID *)jid withNickname:(NSString *)name subject:(NSString *)subject password:(nullable NSString *)password
{
    dispatch_async(moduleQueue, ^{
        if ([subject length]) {
            [self.tempRoomSubject setObject:subject forKey:jid.bare];
        }
    });
    
    //Register view for sending message queue and occupants
    [self.databaseConnection.database asyncRegisterUnsentGroupMessagesView:nil completionBlock:nil];
    [self.databaseConnection.database asyncRegisterGroupOccupantsView:nil completionBlock:nil];
    
    
    XMPPRoom *room = [self.rooms objectForKey:jid.bare];
    NSString* accountId = self.xmppStream.tag;
    NSString *databaseRoomKey = [OTRXMPPRoom createUniqueId:self.xmppStream.tag jid:jid.bare];
    if (!room) {
        
        
        //Update view mappings with this room
        NSArray *groups = [self.unsentMessagesViewHandler groupsArray];
        if (!groups) {
            groups = [[NSArray alloc] init];
        }
        groups = [groups arrayByAddingObject:[OTRXMPPRoom createUniqueId:self.xmppStream.tag jid:jid.bare]];
        NSString *viewName = [YapDatabaseConstants extensionName:DatabaseExtensionNameUnsentGroupMessagesViewName];
        [self.unsentMessagesViewHandler setup:viewName groups:groups];
        
        OTRXMPPRoomYapStorage *storage = [[OTRXMPPRoomYapStorage alloc] initWithDatabaseConnection:self.databaseConnection];
        room = [[XMPPRoom alloc] initWithRoomStorage:storage jid:jid];
        @synchronized(self.rooms) {
            [self.rooms setObject:room forKey:room.roomJID.bare];
        }
        [room activate:self.xmppStream];
        [room addDelegate:self delegateQueue:moduleQueue];
    }
    
    /** Create room database object */
    [self.databaseConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction * _Nonnull transaction) {
        OTRXMPPRoom *room = [[OTRXMPPRoom fetchObjectWithUniqueID:databaseRoomKey transaction:transaction] copy];
        if(!room) {
            room = [[OTRXMPPRoom alloc] init];
            room.lastRoomMessageId = @""; // Hack to make it show up in list
            room.accountUniqueId = accountId;
            room.jid = jid.bare;
        }
        
        //Other Room properties should be set here
        if ([subject length]) {
            room.subject = subject;
        }
        room.roomPassword = password;
        
        [room saveWithTransaction:transaction];
    }];
    
    //Get history if any
    NSXMLElement *historyElement = nil;
    OTRXMPPRoomYapStorage *storage = room.xmppRoomStorage;
    id<OTRMessageProtocol> lastMessage = [storage lastMessageInRoom:room accountKey:accountId];
    NSDate *lastMessageDate = [lastMessage date];
    if (lastMessageDate) {
        //Use since as our history marker if we have a last message
        //http://xmpp.org/extensions/xep-0045.html#enter-managehistory
        NSString *dateTimeString = [lastMessageDate xmppDateTimeString];
        historyElement = [NSXMLElement elementWithName:@"history"];
        [historyElement addAttributeWithName:@"since" stringValue:dateTimeString];
    }
    
    [room joinRoomUsingNickname:name history:historyElement password:password];
    return databaseRoomKey;
}

- (void)leaveRoom:(nonnull XMPPJID *)jid
{
    XMPPRoom *room = [self.rooms objectForKey:jid.bare];
    [room leaveRoom];
}

- (NSString *)startGroupChatWithBuddies:(NSArray<NSString *> *)buddiesArray roomJID:(XMPPJID *)roomName nickname:(nonnull NSString *)name subject:(nullable NSString *)subject
{
    dispatch_async(moduleQueue, ^{
        if ([buddiesArray count]) {
            [self.inviteDictionary setObject:buddiesArray forKey:roomName.bare];
        }
        
        
    });
    
    return [self joinRoom:roomName withNickname:name subject:subject password:nil];
}

- (void)inviteUser:(NSString *)user toRoom:(NSString *)roomJID withMessage:(NSString *)message
{
    XMPPRoom *room = [self.rooms objectForKey:roomJID];
    [room inviteUser:[XMPPJID jidWithString:user] withMessage:message];
}

- (NSMutableDictionary *)rooms {
    if (!_rooms) {
        _rooms = [[NSMutableDictionary alloc] init];
    }
    return _rooms;
}

- (void)handleNewViewItems:(OTRYapViewHandler *)viewHandler {
    NSMutableArray <OTRXMPPRoomMessage *>*messagesTosend = [[NSMutableArray alloc] init];
    [viewHandler.databaseConnection asyncReadWithBlock:^(YapDatabaseReadTransaction * _Nonnull transaction) {
        NSUInteger sections = [viewHandler.mappings numberOfSections];
        for(NSUInteger section = 0; section < sections; section++) {
            NSUInteger rows = [viewHandler.mappings numberOfItemsInSection:section];
            for (NSUInteger row = 0; row < rows; row++) {
                
                OTRXMPPRoomMessage *roomMessage = [[transaction ext:viewHandler.mappings.view] objectAtIndexPath:[NSIndexPath indexPathForRow:row inSection:section] withMappings:viewHandler.mappings];
                if (roomMessage){
                    [messagesTosend addObject:roomMessage];
                }
            }
        }
    } completionQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0) completionBlock:^{
        [self.databaseConnection asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction * _Nonnull transaction) {
            [messagesTosend enumerateObjectsUsingBlock:^(OTRXMPPRoomMessage *roomMessage, NSUInteger idx, BOOL * _Nonnull stop) {
                XMPPRoom *room = [self.rooms objectForKey:roomMessage.roomJID];
                if (room) {
                    XMPPMessage *message = [[self class] xmppMessage:roomMessage];
                    [room sendMessage:message];
                }
                roomMessage.state = RoomMessageStatePendingSent;
                [roomMessage saveWithTransaction:transaction];
            }];
        }];
    }];
}

#pragma - mark XMPPStreamDelegate Methods

- (void)xmppStreamDidAuthenticate:(XMPPStream *)sender {
    
    //Once we've connecected and authenticated we find what room services are available
    [self.mucModule discoverServices];
    //Once we've authenitcated we need to rejoin existing rooms
    NSMutableArray <OTRXMPPRoom *>*roomArray = [[NSMutableArray alloc] init];
    [self.databaseConnection asyncReadWithBlock:^(YapDatabaseReadTransaction * _Nonnull transaction) {
        [transaction enumerateKeysAndObjectsInCollection:[OTRXMPPRoom collection] usingBlock:^(NSString * _Nonnull key, id  _Nonnull object, BOOL * _Nonnull stop) {
            
            if ([object isKindOfClass:[OTRXMPPRoom class]]) {
                OTRXMPPRoom *room = (OTRXMPPRoom *)object;
                if ([room.jid length]) {
                    [roomArray addObject:room];
                }
            }
            
        } withFilter:^BOOL(NSString * _Nonnull key) {
            //OTRXMPPRoom is saved with the jid and account id as part of the key
            if ([key containsString:self.xmppStream.tag]) {
                return YES;
            }
            return NO;
        }];
    } completionQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0) completionBlock:^{
        [roomArray enumerateObjectsUsingBlock:^(OTRXMPPRoom * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            [self joinRoom:[XMPPJID jidWithString:obj.jid] withNickname:self.xmppStream.myJID.bare subject:obj.subject password:obj.roomPassword];
        }];
    }];
}

- (void)xmppStream:(XMPPStream *)sender didFailToSendMessage:(XMPPMessage *)message error:(NSError *)error
{
    //Check id and mark as needs sending
    
}

- (void)xmppStream:(XMPPStream *)sender didSendMessage:(XMPPMessage *)message
{
    //Check id and mark as sent
}

- (void)xmppStream:(XMPPStream *)sender didReceiveMessage:(XMPPMessage *)message
{
    XMPPJID *from = [message from];
    //Check that this is a message for one of our rooms
    if([message isGroupChatMessageWithSubject] && [[self.rooms allKeys] containsObject:from.bare]) {
        
        NSString *subject = [message subject];
        
        NSString *databaseRoomKey = [OTRXMPPRoom createUniqueId:self.xmppStream.tag jid:from.bare];
        
        [self.databaseConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction * _Nonnull transaction) {
            OTRXMPPRoom *room = [OTRXMPPRoom fetchObjectWithUniqueID:databaseRoomKey transaction:transaction];
            room.subject = subject;
            [room saveWithTransaction:transaction];
        }];
        
    }
    
}

#pragma - mark XMPPMUCDelegate Methods

- (void)xmppMUC:(XMPPMUC *)sender didDiscoverServices:(NSArray *)services
{
    NSMutableArray *array = [NSMutableArray arrayWithCapacity:[services count]];
    [services enumerateObjectsUsingBlock:^(NSXMLElement   * _Nonnull element, NSUInteger idx, BOOL * _Nonnull stop) {
        NSString *jid = [element attributeStringValueForName:@"jid"];
        if ([jid length] && [jid containsString:@"conference"]) {
            [array addObject:jid];
            //TODO instead of just checking if it has the word 'confernce' in the name we need to preform a iq 'get' to see it's capabilities.
            
        }
        
    }];
    _conferenceServicesJID = array;
}

- (void)xmppMUC:(XMPPMUC *)sender roomJID:(XMPPJID *)roomJID didReceiveInvitation:(XMPPMessage *)message
{
    // We must check if we trust the person who invited us
    // because some servers will send you invites from anyone
    // We should probably move some of this code upstream into XMPPFramework
    
    // Since XMPP is super great, there are (at least) two ways to receive a room invite.

    // Examples from XEP-0045:
    // Example 124. Room Sends Invitation to New Member:
    //
    // <message from='darkcave@chat.shakespeare.lit' to='hecate@shakespeare.lit'>
    //   <x xmlns='http://jabber.org/protocol/muc#user'>
    //     <invite from='bard@shakespeare.lit'/>
    //     <password>cauldronburn</password>
    //   </x>
    // </message>
    //
    
    // Examples from XEP-0249:
    //
    //
    // Example 1. A direct invitation
    //
    // <message from='crone1@shakespeare.lit/desktop' to='hecate@shakespeare.lit'>
    //   <x xmlns='jabber:x:conference'
    //      jid='darkcave@macbeth.shakespeare.lit'
    //      password='cauldronburn'
    //      reason='Hey Hecate, this is the place for all good witches!'/>
    // </message>
    
    XMPPJID *fromJID = nil;
    NSString *password = nil;
    
    NSXMLElement * roomInvite = [message elementForName:@"x" xmlns:XMPPMUCUserNamespace];
    NSXMLElement * directInvite = [message elementForName:@"x" xmlns:@"jabber:x:conference"];
    if (roomInvite) {
        // XEP-0045
        NSXMLElement * invite  = [roomInvite elementForName:@"invite"];
        fromJID = [XMPPJID jidWithString:[invite attributeStringValueForName:@"from"]];
        password = [roomInvite elementForName:@"password"].stringValue;
    } else if (directInvite) {
        // XEP-0249
        fromJID = [message from];
        password = [directInvite attributeStringValueForName:@"password"];
    }
    if (!fromJID) {
        DDLogWarn(@"Could not parse fromJID from room invite: %@", message);
        return;
    }
    __block OTRXMPPBuddy *buddy = nil;
    NSString *fromJidString = [fromJID bare];
    NSString *accountUniqueId = self.xmppStream.tag;
    [self.databaseConnection readWithBlock:^(YapDatabaseReadTransaction * _Nonnull transaction) {
        buddy = [OTRXMPPBuddy fetchBuddyWithUsername:fromJidString withAccountUniqueId:accountUniqueId transaction:transaction];
    }];
    // We were invited by someone not on our roster. Shady business!
    if (!buddy) {
        DDLogWarn(@"Received room invitation from someone not on our roster! %@ %@", fromJID, message);
        return;
    }
    [self joinRoom:roomJID withNickname:sender.xmppStream.myJID.bare subject:nil password:password];
}

#pragma - mark XMPPRoomDelegate Methods

- (void)xmppRoomDidJoin:(XMPPRoom *)sender
{
    [sender configureRoomUsingOptions:[[self class] defaultRoomConfiguration]];
    
    dispatch_async(moduleQueue, ^{
        
        //Set Rome Subject
        NSString *subject = [self.tempRoomSubject objectForKey:sender.roomJID.bare];
        if (subject) {
            [self.tempRoomSubject removeObjectForKey:sender.roomJID.bare];
            [sender changeRoomSubject:subject];
        }
        
        //Invite buddies
        NSArray *arary = [self.inviteDictionary objectForKey:sender.roomJID.bare];
        if ([arary count]) {
            [self.databaseConnection readWithBlock:^(YapDatabaseReadTransaction * _Nonnull transaction) {
                [arary enumerateObjectsUsingBlock:^(NSString *  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                    OTRBuddy *buddy = [OTRBuddy fetchObjectWithUniqueID:obj transaction:transaction];
                    if (buddy) {
                        [self inviteUser:buddy.username toRoom:sender.roomJID.bare withMessage:nil];
                    }
                }];
            }];
        }
    });
    
}

#pragma - mark OTRYapViewHandlerDelegateProtocol Methods

- (void)didReceiveChanges:(OTRYapViewHandler *)handler sectionChanges:(NSArray<YapDatabaseViewSectionChange *> *)sectionChanges rowChanges:(NSArray<YapDatabaseViewRowChange *> *)rowChanges
{
    [self handleNewViewItems:handler];
}

- (void)didSetupMappings:(OTRYapViewHandler *)handler
{
    [self handleNewViewItems:handler];
}

#pragma - mark Class Methods

+ (NSXMLElement *)defaultRoomConfiguration
{
    NSXMLElement *form = [[NSXMLElement alloc] initWithName:@"x" xmlns:@"jabber:x:data"];
    [form addAttributeWithName:@"typ" stringValue:@"form"];
    
    NSXMLElement *publicField = [[NSXMLElement alloc] initWithName:@"field"];
    [publicField addAttributeWithName:@"var" stringValue:@"muc#roomconfig_publicroom"];
    [publicField addChild:[[NSXMLElement alloc] initWithName:@"value" numberValue:@(0)]];
    
    NSXMLElement *persistentField = [[NSXMLElement alloc] initWithName:@"field"];
    [publicField addAttributeWithName:@"var" stringValue:@"muc#roomconfig_persistentroom"];
    [publicField addChild:[[NSXMLElement alloc] initWithName:@"value" numberValue:@(1)]];
    
    NSXMLElement *whoisField = [[NSXMLElement alloc] initWithName:@"field"];
    [publicField addAttributeWithName:@"var" stringValue:@"muc#roomconfig_whois"];
    [publicField addChild:[[NSXMLElement alloc] initWithName:@"value" stringValue:@"anyone"]];
    
    [form addChild:publicField];
    [form addChild:persistentField];
    [form addChild:whoisField];
    
    return form;
}

+ (XMPPMessage *)xmppMessage:(OTRXMPPRoomMessage *)databaseMessage {
    NSXMLElement *body = [NSXMLElement elementWithName:@"body" stringValue:databaseMessage.text];
    XMPPMessage *message = [XMPPMessage message];
    [message addChild:body];
    [message addAttributeWithName:@"id" stringValue:databaseMessage.xmppId];
    return message;
}
@end
