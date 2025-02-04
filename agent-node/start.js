const { ethers } = require('ethers');
const fs = require('fs');
const lmdb = require("lmdb")
const path = require('path');
const agent=require("./agent.json")
const readline = require("readline")
const config = require("./config.json")
const PRIVATE_KEY = config.privkeyMnemonic;
const PROVIDER_URL = config.rpcUrl;
const CONTRACT_ADDRESS = config.contractAddress;
const CONTRACT_ABI = require("./AgentContract-ABI.json")
async function main() {
    const db = await initializeDB(config)
    const provider = new ethers.JsonRpcProvider(PROVIDER_URL);
    const wallet = ethers.Wallet.fromPhrase(PRIVATE_KEY, provider);
    const contract = new ethers.Contract(CONTRACT_ADDRESS, CONTRACT_ABI, wallet);
    let myBonding = await contract.bondedBalances(wallet.address)
    const submissionThreshold = await contract.submissionThreshold()

    console.log(`Using wallet address: ${wallet.address}`);
    console.log("My bonding:" + await contract.bondedBalances(wallet.address))

    if (myBonding < submissionThreshold) {
        console.log("Bonding coins to be able to vote")
        console.log(submissionThreshold)
        if (await confirm("Do you want to bond " + ethers.formatEther(submissionThreshold.toString()) + " coins?")) {
            let tx = await contract.bond({ value: submissionThreshold })
            await tx.wait()
            console.log("Bonded successfully!")
        } else {
            console.log("Cannot continue without bonded balance")
            process.exit()
        }
    }

    downloadContext(contract, db)
    console.log("Latest context:",)
}
async function downloadContext(contract, db) {
    let currentLatestSubmission = db.get("latestSubmission")
    let synced = false
    while (true) {
        try {
            let latestSubmission = await contract.getSubmittedTokens(currentLatestSubmission + 1);
            await db.put("submission-" + (currentLatestSubmission + 1), latestSubmission)
            await db.put("latestSubmission", currentLatestSubmission + 1)
            currentLatestSubmission += 1
            console.log("Downloaded submission", currentLatestSubmission)
        } catch (e) {
            if (!synced) {
                synced = true
                console.log("Synced all submissions")
                startOperating(db, contract)
            }
            await new Promise((resolve) => {
                setTimeout(resolve, 1000);
            });
            continue
        }
    }

}
async function startOperating(db, contract) {
    const { getLlama, LlamaChat} = await import("node-llama-cpp")
    const llama = await getLlama();
    const model = await llama.loadModel({ modelPath: path.join(__dirname, "..", "models", "phi-4-Q5_K_M.gguf"), defaultContextFlashAttention: true, useMlock: true })
    const context= await model.createContext();
    const llamaChat= new LlamaChat({contextSequence: context.getSequence()});


    while (true) {
        let currentLatestSubmission = db.get("latestSubmission")
      
        let chatHistory= llamaChat.chatWrapper.generateInitialChatHistory({
            systemPrompt: agent.system
        });
        for(let i=currentLatestSubmission-5; i<=currentLatestSubmission; i++){
            let submission=db.get("submission"+i)
            if(submission){
            chatHistory.push({type:"user",text:"Produce thought/interaction/inner monologue number "+i+", remember to account for previous interactions and roleplay the character. Proceeed right to roleplay without elaboration."})
            chatHistory.push({type:"model",response:[model.detokenize(submission.map(s=>parseInt(s)))]})
            }
        }
        chatHistory.push({type:"user",text:"Produce thought/interaction/inner monologue number "+currentLatestSubmission+1+", remember to account for previous interactions and roleplay the character. Proceeed right to roleplay without elaboration."})
        chatHistory.push({type:"model",response:[]})
        const nextSubmission= await llamaChat.generateResponse(chatHistory,{seed:currentLatestSubmission+41});
        
        if(db.get("latestSubmission")==currentLatestSubmission){
            console.log("Submitting new thought:\n"+nextSubmission.response)
            await contract.propose(model.tokenize(nextSubmission.response).map(s=>BigInt(s)))
        }
        
    }
}
function askQuestion(query) {
    const rl = readline.createInterface({
        input: process.stdin,
        output: process.stdout,
    });
    return new Promise((resolve) => {
        rl.question(query, (answer) => {
            resolve(answer.trim());
            rl.close()
        });

    });
}
function confirm(question) {
    const rl = readline.createInterface({
        input: process.stdin,
        output: process.stdout,
    });
    return new Promise((resolve) => {
        rl.question(question + " (yes/no)", (answer) => {
            resolve(answer.toLowerCase().startsWith("y") ? true : false);
            rl.close()
        });

    });
}
async function initializeDB(config) {
    let db = lmdb.open(config.dbPath)
    if (db.get("latestSubmission") === undefined) {
        await db.put("latestSubmission", 0)
        await db.put("submission-0", [])
    }
    return db
}
main()