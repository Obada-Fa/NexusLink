package com.nexuslink.nexuslink

data class PetSessionSummary(
    val id:String,val title:String,val project:String,val agent:String,
    val status:String,val detail:String,val updatedAt:Long,val priority:Int,val running:Boolean,val preview:String=""
)

fun petProject(path:String):String=path.replace('\\','/').trimEnd('/').substringAfterLast('/').ifBlank{"No project"}

fun petSessionSummary(id:String,title:String,project:String,agent:String,state:String,busy:Boolean,
                      activity:String,updatedAt:Long,external:Boolean=false):PetSessionSummary {
    val status=when(state){
        "waiting","needsReply"->"Needs your attention"
        "failed"->"Failed"
        "completed"->"Finished"
        "canceled"->"Canceled"
        "interrupted"->"Interrupted"
        "unknown"->if(busy)"Running" else "Status unavailable"
        else->if(busy || state in listOf("running","working"))"Running" else "Idle"
    }
    val running=status=="Running"
    val detail=when {
        status=="Needs your attention"->"Waiting for a reply or approval"
        status=="Interrupted"->"Check the original run on your PC"
        running->when(activity){
            "editing"->"Editing files";"reading"->"Reading / searching"
            "running-command"->"Running a command";"thinking"->"Thinking"
            "responding"->"Writing a response"
            else->if(external)"Working on PC" else "Working"
        }
        external->"Saved GUI status · completion not confirmed"
        else->""
    }
    val priority=when(status){"Needs your attention"->0;"Failed","Interrupted"->1;"Running"->2;"Finished"->3;else->4}
    val provider=when(agent.lowercase()){"codex"->"Codex";"antigravity"->"Antigravity";"claude"->"Claude";"opencode"->"OpenCode";"cursor"->"Cursor";else->agent.ifBlank{"Agent"}}
    return PetSessionSummary(id,title.ifBlank{"Untitled session"},petProject(project),provider,status,detail,updatedAt,priority,running)
}

/** Keep attention and live work out of the recent-history page. */
data class PetConversationGroups(val attention:List<PetSessionSummary>,val running:List<PetSessionSummary>,val recent:List<PetSessionSummary>)
fun petConversationGroups(rows:List<PetSessionSummary>):PetConversationGroups {
    val sorted=rows.distinctBy{it.id}.sortedByDescending{it.updatedAt}
    return PetConversationGroups(sorted.filter{it.priority<=1},sorted.filter{it.running},
        sorted.filter{it.priority>1 && !it.running})
}
