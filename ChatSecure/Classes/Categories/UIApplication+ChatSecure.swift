//
//  UIApplication+ChatSecure.swift
//  ChatSecure
//
//  Created by David Chiles on 12/14/15.
//  Copyright © 2015 Chris Ballinger. All rights reserved.
//

import Foundation
import MWFeedParser
import UserNotifications
import OTRAssets

public extension UIApplication {
    
    public func showLocalNotification(_ message:OTRMessageProtocol) {
        var thread:OTRThreadOwner? = nil
        var unreadCount:UInt = 0
        
        OTRDatabaseManager.sharedInstance().readOnlyDatabaseConnection?.read({ (transaction) -> Void in
            unreadCount = transaction.numberOfUnreadMessages()
            thread = message.threadOwner(with: transaction)
        })
        
        guard let threadOwner = thread else {
            return
        }
        
        let threadName = threadOwner.threadName()
        
        var text = "\(threadName)"
        if let msgTxt = message.text() {
            if let rawMessageString = msgTxt.convertingHTMLToPlainText() {
                text += ": \(rawMessageString)"
            }
        }
        
        
        self.showLocalNotificationFor(threadOwner, text: text, unreadCount: Int(unreadCount))
    }
    
    public func showLocalNotificationForKnockFrom(_ thread:OTRThreadOwner?) {
        var name = SOMEONE_STRING()
        if let threadName = thread?.threadName() {
            name = threadName
        }
        
        let chatString = WANTS_TO_CHAT_STRING()
        let text = "\(name) \(chatString)"
        let unreadCount = self.applicationIconBadgeNumber + 1
        self.showLocalNotificationFor(thread, text: text, unreadCount: unreadCount)
    }
    
    public func showLocalNotificationForSubscriptionRequestFrom(_ jid:String?) {
        var name = SOMEONE_STRING()
        if let jidName = jid {
            name = jidName
        }
        
        let chatString = WANTS_TO_CHAT_STRING()
        let text = "\(name) \(chatString)"
        let unreadCount = self.applicationIconBadgeNumber + 1
        self.showLocalNotificationFor(nil, text: text, unreadCount: unreadCount)
    }
    
    public func showLocalNotificationForApprovedBuddy(_ thread:OTRThreadOwner?) {
        var name = SOMEONE_STRING()
        if let buddyName = (thread as? OTRBuddy)?.displayName {
            name = buddyName
        } else if let threadName = thread?.threadName() {
            name = threadName
        }
        
        let message = String(format: BUDDY_APPROVED_STRING(), name)
        
        let unreadCount = self.applicationIconBadgeNumber + 1
        self.showLocalNotificationFor(thread, text: message, unreadCount: unreadCount)
    }
    
    internal func showLocalNotificationFor(_ thread:OTRThreadOwner?, text:String, unreadCount:Int) {
        DispatchQueue.main.async {
            // Use the new UserNotifications.framework on iOS 10+
            if #available(iOS 10.0, *) {
                let localNotification = UNMutableNotificationContent()
                localNotification.body = text
                localNotification.badge = NSNumber(integerLiteral: unreadCount)
                localNotification.sound = UNNotificationSound.default()
                if let t = thread {
                    localNotification.threadIdentifier = t.threadIdentifier()
                    localNotification.userInfo = [kOTRNotificationThreadKey:t.threadIdentifier(), kOTRNotificationThreadCollection:t.threadCollection()]
                }
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: localNotification, trigger: nil) // Schedule the notification.
                let center = UNUserNotificationCenter.current()
                center.add(request, withCompletionHandler: { (error: Error?) in
                    if let error = error as NSError? {
                        #if DEBUG
                            NSLog("Error scheduling notification! %@", error)
                        #endif
                    }
                })
            } else if(self.applicationState != .active) {
                let localNotification = UILocalNotification()
                localNotification.alertAction = REPLY_STRING()
                localNotification.soundName = UILocalNotificationDefaultSoundName
                localNotification.applicationIconBadgeNumber = unreadCount
                localNotification.alertBody = text
                if let t = thread {
                    localNotification.userInfo = [kOTRNotificationThreadKey:t.threadIdentifier(), kOTRNotificationThreadCollection:t.threadCollection()]
                }
                self.presentLocalNotificationNow(localNotification)
            }
        }
    }
    
}
