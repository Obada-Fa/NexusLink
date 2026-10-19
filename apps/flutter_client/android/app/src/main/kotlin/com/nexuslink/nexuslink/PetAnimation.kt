package com.nexuslink.nexuslink

/** Time-based animation policy, independent of Android and of network refresh rate. */
enum class PetMood { IDLE, WORKING, WAITING, ERROR, COMPLETE, OFFLINE }
enum class PetClip(val row:Int,val frameMs:Long) {
    IDLE(0,420), WALK(1,120), RUN(2,85), CALL(3,120), PLAY(4,140),
    SLEEP(5,520), ATTENTION(6,250), SNIFF(7,180)
}
data class PetPose(val clip:PetClip,val frame:Int,val celebrating:Boolean=false)

class PetAnimation(private val startedAt:Long) {
    var mood=PetMood.IDLE; private set
    private var changedAt=startedAt
    private var playUntil=0L
    private var celebrateUntil=0L
    private var dragged=false

    fun status(next:PetMood,now:Long){
        if(next==mood)return
        if(next==PetMood.COMPLETE && mood==PetMood.WORKING)celebrateUntil=now+2400
        if(next in listOf(PetMood.OFFLINE,PetMood.ERROR,PetMood.WAITING)){
            playUntil=0;celebrateUntil=0
        }
        mood=next;changedAt=now
    }
    fun play(now:Long){playUntil=now+2200}
    fun drag(value:Boolean){dragged=value}
    fun pose(now:Long,reducedMotion:Boolean=false):PetPose {
        val age=(now-changedAt).coerceAtLeast(0)
        val celebrate=!dragged && now<celebrateUntil && !reducedMotion
        val clip=when {
            dragged->PetClip.ATTENTION
            celebrate || now<playUntil->PetClip.PLAY
            mood==PetMood.OFFLINE->PetClip.SLEEP
            mood==PetMood.WAITING->if(age%6000<600)PetClip.CALL else PetClip.ATTENTION
            mood==PetMood.ERROR->PetClip.ATTENTION
            mood==PetMood.WORKING->if(age%9000<6500)PetClip.RUN else PetClip.SNIFF
            age>45000->PetClip.SLEEP
            age%18000 in 10000..12499->PetClip.SNIFF
            age%18000 in 12500..14999->PetClip.WALK
            else->PetClip.IDLE
        }
        // A frozen, representative pose when animations are disabled.
        val frame=if(reducedMotion)if(clip==PetClip.SLEEP)2 else 0
            else (((now-startedAt).coerceAtLeast(0)/clip.frameMs)%4).toInt()
        return PetPose(clip,frame,celebrate)
    }
}
