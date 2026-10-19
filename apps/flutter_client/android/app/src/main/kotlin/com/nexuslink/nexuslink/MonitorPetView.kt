package com.nexuslink.nexuslink

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.*
import android.os.SystemClock
import android.view.View
import kotlin.math.*

/** Bundled MIT fox artwork, rendered natively with no WebView or Flutter engine. */
class MonitorPetView(context:Context):View(context) {
    private val paint=Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
    private val source=Rect()
    private val target=RectF()
    private val animation=PetAnimation(SystemClock.uptimeMillis())
    private val atlas= context.assets.open("pets/fox/fox-atlas.png").use { BitmapFactory.decodeStream(it) }
        ?: error("Bundled fox atlas is missing")
    private var tint=0xFF93C5FD.toInt()
    private var badge="•"
    private var reducedMotion=false
    private var faceLeft=false
    private var dragging=false
    private var tilt=0f
    private var releasedAt=0L
    private var attached=false
    private var scheduled=false
    private val tick=Runnable {
        scheduled=false
        if(attached && windowVisibility==VISIBLE){invalidate();schedule()}
    }
    private fun schedule(){
        if(scheduled || !attached || windowVisibility!=VISIBLE)return
        scheduled=true
        // Sleep/idle use their source cadence; active gestures/effects cap at 25 fps.
        val pose=animation.pose(SystemClock.uptimeMillis(),motionReduced())
        val active=dragging || pose.celebrating || SystemClock.uptimeMillis()-releasedAt<700 ||
            pose.clip in listOf(PetClip.RUN,PetClip.PLAY,PetClip.WALK)
        postDelayed(tick,if(motionReduced())1000 else if(active)40 else pose.clip.frameMs)
    }
    private fun motionReduced()=reducedMotion || (android.os.Build.VERSION.SDK_INT>=26 && !ValueAnimator.areAnimatorsEnabled())
    private fun wake(){removeCallbacks(tick);scheduled=false;invalidate();schedule()}
    fun status(mood:PetMood,label:String,color:Int){
        animation.status(mood,SystemClock.uptimeMillis());badge=label;tint=color;invalidate()
    }
    fun setReducedMotion(value:Boolean){reducedMotion=value;wake()}
    fun faceInward(onRightEdge:Boolean){faceLeft=onRightEdge;invalidate()}
    fun dragBy(dx:Float){
        dragging=true;animation.drag(true)
        if(abs(dx)>2f)faceLeft=dx<0
        tilt=(dx/4f).coerceIn(-12f,12f);wake()
    }
    fun release(){dragging=false;animation.drag(false);tilt=0f;releasedAt=SystemClock.uptimeMillis();wake()}
    fun play(){animation.play(SystemClock.uptimeMillis());wake()}
    override fun onAttachedToWindow(){super.onAttachedToWindow();attached=true;wake()}
    override fun onDetachedFromWindow(){attached=false;removeCallbacks(tick);scheduled=false;super.onDetachedFromWindow()}
    override fun onWindowVisibilityChanged(visibility:Int){
        super.onWindowVisibilityChanged(visibility)
        if(visibility==VISIBLE && attached)wake() else {removeCallbacks(tick);scheduled=false}
    }
    override fun performClick():Boolean {super.performClick();play();return true}

    override fun onDraw(canvas:Canvas){
        super.onDraw(canvas)
        val now=SystemClock.uptimeMillis()
        val still=motionReduced()
        val pose=animation.pose(now,still)
        val seconds=now/1000.0
        canvas.save();canvas.scale(width/104f,height/104f)
        paint.style=Paint.Style.FILL
        paint.color=Color.argb(34,0,0,0)
        canvas.drawOval(19f,87f,85f,96f,paint)
        paint.color=Color.argb(45,Color.red(tint),Color.green(tint),Color.blue(tint))
        canvas.drawOval(27f,89f,77f,94f,paint)

        var hop=0f
        var squash=1f
        if(!still){
            if(pose.celebrating || pose.clip==PetClip.PLAY)hop=abs(sin(seconds*7)).toFloat()*7f
            else if(pose.clip==PetClip.RUN)hop=abs(sin(seconds*12)).toFloat()*1.7f
            val releaseAge=now-releasedAt
            if(releaseAge in 0..700)squash=1f+(sin(releaseAge/55.0)*exp(-releaseAge/180.0)*0.10).toFloat()
        }
        canvas.save()
        canvas.translate(52f,91f-hop)
        if(dragging && !still){canvas.translate(0f,-5f);canvas.rotate(tilt)}
        canvas.scale(if(faceLeft)-1f/squash else 1f/squash,squash)
        source.set(pose.frame*224,pose.clip.row*224,(pose.frame+1)*224,(pose.clip.row+1)*224)
        target.set(-48f,-86f,48f,10f)
        paint.color=Color.WHITE;paint.alpha=255
        canvas.drawBitmap(atlas,source,target,paint)
        canvas.restore()

        // Small readable signal stays separate from the character's expressions.
        paint.color=0xF01B2437.toInt();canvas.drawCircle(86f,16f,11f,paint)
        paint.color=tint;paint.textSize=13f;paint.typeface=Typeface.DEFAULT_BOLD;paint.textAlign=Paint.Align.CENTER
        canvas.drawText(badge.take(3),86f,20.5f,paint)
        if(pose.clip==PetClip.SLEEP){
            paint.color=0xFFC7D5EF.toInt();paint.textSize=12f
            val rise=if(still)0f else ((seconds%2.5)/2.5*8).toFloat()
            canvas.drawText("z",67f,35f-rise,paint);paint.textSize=9f;canvas.drawText("z",77f,26f-rise,paint)
        }
        if(pose.celebrating){
            for(i in 0..5){
                val phase=((seconds*0.8+i/6.0)%1).toFloat()
                val angle=i*Math.PI/3
                val radius=18f+phase*27f
                val x=52f+cos(angle).toFloat()*radius
                val y=49f+sin(angle).toFloat()*radius-phase*9f
                paint.color=if(i%2==0)0xFFFFD670.toInt() else 0xFF7EE8CB.toInt()
                paint.alpha=((1-phase)*230).toInt()
                canvas.drawCircle(x,y,2.4f*(1-phase)+0.5f,paint)
            }
            paint.alpha=255
        }
        canvas.restore()
    }
}
