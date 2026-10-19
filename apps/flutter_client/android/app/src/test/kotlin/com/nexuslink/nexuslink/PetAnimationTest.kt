package com.nexuslink.nexuslink

import org.junit.Assert.*
import org.junit.Test

class PetAnimationTest {
    @Test fun repeatedNetworkSnapshotsDoNotRestartTheAnimation(){
        val pet=PetAnimation(0)
        pet.status(PetMood.WORKING,0)
        pet.status(PetMood.WORKING,7000)
        assertEquals(PetClip.SNIFF,pet.pose(7000).clip)
    }
    @Test fun completionCelebratesOnceThenSettles(){
        val pet=PetAnimation(0)
        pet.status(PetMood.WORKING,0)
        pet.status(PetMood.COMPLETE,1000)
        assertTrue(pet.pose(1100).celebrating)
        pet.status(PetMood.COMPLETE,3000)
        assertFalse(pet.pose(3500).celebrating)
        assertEquals(PetClip.IDLE,pet.pose(3500).clip)
    }
    @Test fun oldCompletedTasksDoNotProduceFalseCelebrations(){
        val pet=PetAnimation(0)
        pet.status(PetMood.COMPLETE,1000)
        assertFalse(pet.pose(1100).celebrating)
    }
    @Test fun urgentStatusInterruptsPlayAndCelebration(){
        val pet=PetAnimation(0)
        pet.play(0)
        pet.status(PetMood.ERROR,100)
        assertEquals(PetClip.ATTENTION,pet.pose(200).clip)
        pet.status(PetMood.OFFLINE,300)
        assertEquals(PetClip.SLEEP,pet.pose(400).clip)
    }
    @Test fun dragTemporarilyOverridesSleep(){
        val pet=PetAnimation(0)
        pet.status(PetMood.OFFLINE,0)
        pet.drag(true)
        assertEquals(PetClip.ATTENTION,pet.pose(50).clip)
        pet.drag(false)
        assertEquals(PetClip.SLEEP,pet.pose(100).clip)
    }
    @Test fun reducedMotionFreezesFramesAndSuppressesConfetti(){
        val pet=PetAnimation(0)
        pet.status(PetMood.WORKING,0)
        pet.status(PetMood.COMPLETE,1000)
        assertFalse(pet.pose(1100,true).celebrating)
        assertEquals(0,pet.pose(1100,true).frame)
        pet.status(PetMood.OFFLINE,2000)
        assertEquals(2,pet.pose(2500,true).frame)
    }
    @Test fun allPosesStayInsideTheBundledAtlas(){
        for(mood in PetMood.values()){
            val pet=PetAnimation(0);pet.status(mood,0)
            for(time in 0L..120000L step 41){
                val pose=pet.pose(time)
                assertTrue(pose.frame in 0..3)
                assertTrue(pose.clip.row in 0..7)
            }
        }
    }
}
