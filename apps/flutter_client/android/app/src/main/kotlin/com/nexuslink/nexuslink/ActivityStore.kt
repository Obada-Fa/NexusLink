package com.nexuslink.nexuslink

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper

/** Local alert progress; credentials remain in the existing Keystore storage. */
data class PendingNotificationAction(val operation:String,val hostId:String,val url:String,val task:String,val turn:String,val source:Long,val action:String,val request:String?,val text:String?,val state:String,val created:Long,val reason:String?)

data class PendingCard(val tag:String,val id:Int,val payload:String)

class ActivityStore(context:Context):SQLiteOpenHelper(context,"live_activity.sqlite",null,3) {
    override fun onCreate(db:SQLiteDatabase) {
        db.execSQL("CREATE TABLE cursor_state(host TEXT PRIMARY KEY, cursor INTEGER NOT NULL)")
        db.execSQL("CREATE TABLE notifications(tag TEXT PRIMARY KEY, id INTEGER NOT NULL UNIQUE, pending_payload TEXT)")
        db.execSQL("CREATE TABLE operations(operation TEXT PRIMARY KEY, host TEXT NOT NULL, url TEXT NOT NULL, task TEXT NOT NULL, turn TEXT NOT NULL, source INTEGER NOT NULL, action TEXT NOT NULL, request TEXT, text TEXT, state TEXT NOT NULL, created INTEGER NOT NULL, reason TEXT)")
    }
    override fun onUpgrade(db:SQLiteDatabase,oldVersion:Int,newVersion:Int) {
        if(oldVersion<2)db.execSQL("ALTER TABLE operations ADD COLUMN url TEXT NOT NULL DEFAULT ''")
        if(oldVersion<3)db.execSQL("ALTER TABLE notifications ADD COLUMN pending_payload TEXT")
    }

    fun cursor(host:String):Long = readableDatabase.rawQuery("SELECT cursor FROM cursor_state WHERE host=?",arrayOf(host)).use {
        if(it.moveToFirst())it.getLong(0) else 0L
    }

    /** Cursor and stable notification identity advance in one transaction. */
    fun commit(host:String,cursor:Long,tag:String?,payload:String?=null):Int? {
        val db=writableDatabase
        db.beginTransaction()
        try {
            var id:Int?=null
            if(tag!=null) {
                db.rawQuery("SELECT id FROM notifications WHERE tag=?",arrayOf(tag)).use { if(it.moveToFirst())id=it.getInt(0) }
                if(id==null) {
                    id=(db.rawQuery("SELECT COALESCE(MAX(id),10000)+1 FROM notifications",null).use { it.moveToFirst();it.getInt(0) })
                    db.execSQL("INSERT INTO notifications(tag,id,pending_payload) VALUES (?,?,?)",arrayOf<Any?>(tag,id,payload))
                } else if(payload!=null) {
                    db.execSQL("UPDATE notifications SET pending_payload=? WHERE tag=?",arrayOf<Any?>(payload,tag))
                }
            }
            db.execSQL("INSERT INTO cursor_state(host,cursor) VALUES (?,?) ON CONFLICT(host) DO UPDATE SET cursor=MAX(cursor,excluded.cursor)",arrayOf<Any?>(host,cursor))
            db.setTransactionSuccessful()
            return id
        } finally { db.endTransaction() }
    }

    fun id(tag:String):Int?=readableDatabase.rawQuery("SELECT id FROM notifications WHERE tag=?",arrayOf(tag)).use {if(it.moveToFirst())it.getInt(0) else null}

    fun pendingCards(host:String):List<PendingCard> = readableDatabase.rawQuery(
        "SELECT tag,id,pending_payload FROM notifications WHERE pending_payload IS NOT NULL",null
    ).use { cursor ->
        val rows=mutableListOf<PendingCard>()
        while(cursor.moveToNext()){
            val tag=cursor.getString(0)
            if(tag.contains(":$host:"))rows.add(PendingCard(tag,cursor.getInt(1),cursor.getString(2)))
        }
        rows
    }

    fun markPosted(tag:String) { writableDatabase.execSQL("UPDATE notifications SET pending_payload=NULL WHERE tag=?",arrayOf(tag)) }

    fun tags():List<Pair<String,Int>> = readableDatabase.rawQuery("SELECT tag,id FROM notifications",null).use {
        val rows=mutableListOf<Pair<String,Int>>()
        while(it.moveToNext())rows.add(it.getString(0) to it.getInt(1))
        rows
    }

    fun claimAction(row:PendingNotificationAction):Boolean {
        val db=writableDatabase
        db.beginTransaction()
        try {
            val old=action(row.operation)
            if(old!=null){
                if(old.hostId!=row.hostId || old.url!=row.url || old.task!=row.task || old.turn!=row.turn ||
                    old.source!=row.source || old.action!=row.action || old.request!=row.request || old.text!=row.text)
                    throw IllegalArgumentException("Action identity was reused with different content")
                db.setTransactionSuccessful();return false
            }
            db.execSQL("INSERT INTO operations(operation,host,url,task,turn,source,action,request,text,state,created,reason) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                arrayOf<Any?>(row.operation,row.hostId,row.url,row.task,row.turn,row.source,row.action,row.request,row.text,row.state,row.created,row.reason))
            db.setTransactionSuccessful()
            return true
        } finally {db.endTransaction()}
    }

    fun action(operation:String):PendingNotificationAction?=readableDatabase.rawQuery(
        "SELECT operation,host,url,task,turn,source,action,request,text,state,created,reason FROM operations WHERE operation=?",arrayOf(operation)).use {
        if(!it.moveToFirst())null else PendingNotificationAction(it.getString(0),it.getString(1),it.getString(2),it.getString(3),it.getString(4),it.getLong(5),it.getString(6),it.getString(7),it.getString(8),it.getString(9),it.getLong(10),it.getString(11))
    }

    fun updateAction(operation:String,state:String,reason:String?=null) {
        writableDatabase.execSQL("UPDATE operations SET state=?,reason=? WHERE operation=?",arrayOf<Any?>(state,reason,operation))
    }

    fun queuedActions():List<String> = readableDatabase.rawQuery("SELECT operation FROM operations WHERE state='queued' AND created>?",arrayOf((System.currentTimeMillis()-30000).toString())).use {
        val rows=mutableListOf<String>();while(it.moveToNext())rows.add(it.getString(0));rows
    }
}
