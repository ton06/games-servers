const AWS = require('aws-sdk')
const ecs = new AWS.ECS()
const ec2 = new AWS.EC2()

function log(message, context) {
    console.log(JSON.stringify({ message, ...context }))
}

// up handler
exports.handler = async () => {

    // get env vars
    const cluster = process.env.CLUSTER
    const service = process.env.SERVICE
    const bucket = process.env.BUCKET

    // start
    await ecs.updateService({ cluster, service, desiredCount: 1 }).promise()
    log("started", { cluster, service })

    // wait until stable
    await ecs.waitFor("servicesStable", { cluster, services: [service] }).promise()
    log("service stable", { cluster, service })

    // get task
    const task = await ecs.listTasks({ cluster, serviceName: service }).promise()
        .then(res => res.taskArns[0])

    // wait until task stable / get ENI
    const eni = await ecs.waitFor("tasksRunning", { cluster, tasks: [task] }).promise()
        .then(res => res.tasks[0].attachments[0].details.filter(a => a.name == "networkInterfaceId")[0].value)
    log("task stable", { cluster, service, task })

    // get PublicIP
    const ip = await ec2.describeNetworkInterfaces({ NetworkInterfaceIds: [eni] }).promise()
        .then(res => res.NetworkInterfaces[0].Association.PublicIp)

    // respond
    return { message: "started", ip, bucket }

}