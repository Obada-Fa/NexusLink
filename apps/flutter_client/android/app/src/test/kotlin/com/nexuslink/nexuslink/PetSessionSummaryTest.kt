package com.nexuslink.nexuslink
import org.junit.Assert.*
import org.junit.Test
class PetSessionSummaryTest {
    private fun summary(state:String,busy:Boolean=false,activity:String="",external:Boolean=false)=
        petSessionSummary("id","Fix login","C:\\work\\NexusLink\\","codex",state,busy,activity,100,external)
    @Test fun projectHandlesBothPlatforms(){
        assertEquals("NexusLink",summary("running").project)
        assertEquals("NexusLink",petProject("/home/user/NexusLink/"))
        assertEquals("No project",petProject(""))
    }
    @Test fun waitingAndTerminalStatesOverrideBusyFlag(){
        assertEquals("Needs your attention",summary("waiting",true).status)
        assertEquals("Finished",summary("completed",true).status)
        assertFalse(summary("completed",true).running)
        assertEquals("Failed",summary("failed",true).status)
    }
    @Test fun activityIsOnlyShownWhileRunning(){
        assertEquals("Editing files",summary("running",true,"editing").detail)
        assertEquals("Running a command",summary("running",true,"running-command").detail)
        assertEquals("",summary("completed",false,"editing").detail)
    }
    @Test fun guiIdleNeverClaimsCompletion(){
        assertEquals("Idle",summary("idle",external=true).status)
        assertTrue(summary("idle",external=true).detail.contains("not confirmed"))
        assertEquals("Status unavailable",summary("unknown",external=true).status)
    }
    @Test fun attentionComesBeforeWorkAndCompletedSessions(){
        val cards=listOf(summary("completed"),summary("running",true),summary("failed"),summary("waiting"))
        assertEquals(listOf("Needs your attention","Failed","Running","Finished"),cards.sortedBy{it.priority}.map{it.status})
    }
    @Test fun groupsKeepActiveConversationsOutOfRecentAndSortByRecency(){
        val oldRun=summary("running",true).copy(id="running",updatedAt=1)
        val recent=summary("completed").copy(id="recent",updatedAt=500)
        val older=summary("idle").copy(id="older",updatedAt=200)
        val waiting=summary("waiting").copy(id="waiting")
        val groups=petConversationGroups(listOf(recent,oldRun,older,waiting,oldRun))
        assertEquals(listOf("waiting"),groups.attention.map{it.id})
        assertEquals(listOf("running"),groups.running.map{it.id})
        assertEquals(listOf("recent","older"),groups.recent.map{it.id})
    }
}
