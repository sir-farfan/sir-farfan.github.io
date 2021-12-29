---
layout: post
title:  "Elastic Search conditional update by timestamp"
date:   2021-12-29 14:35:50 -0600
categories: ES ElasticSearch Update
---
I worked on a data sink system with a multitude of producers that may send updated versions of statistics objects through the network, such objects aren't partial updates, but actual full objects that have to be saved in Elastic Search, which means all the existing data is to be replaced or created if it's new, all while making sure of keeping only the latest version in ES for further search.

![Architecture](/graphics/ESCondUpdateArch1.png)

Network being what it is, introduces a nice little issue: updates are bound to arrive out of order, meaning older date can arrive after newer one, hence the need of verifying in ES before sending updates; this in turn introduces more overhead and isn't really a guarantee when having horizontal scaling of data sink service workers.

Let's simplify everything and say this is our payload:
```json
{
    "customer": "sir-farfan",
    "notes": "for blogging purposes",
    "timestamp": 1640791921
}
```

Makings thousands of objects updates per minute actually posses a few issues for the network bandwidth, the more threads we launch to retrieve and update packages asynchronous, the higher the latency on rush hours. A very simple simple optimization gave us a speedup of 20%: we only retrieve the timestamp with [_source_includes][source-includes] instead of the whole object, if the object doesn't exists, the timestamp is initialized with epoch on unmarshal, which is OK for us.

```sql
GET blog/text/1/?_source_includes=timestamp
```
Result:
```json
{
    "_index": "blog",
    "_type": "text",
    "_id": "1",
    "_version": 1,
    "_seq_no": 0,
    "_primary_term": 1,
    "found": true,
    "_source": {
        "timestamp": 1640791921
    }
}
```

That 20% speedup, just by retrieving the timestamp instead of the whole thing, made it crystal clear that we're dealing with a bandwidth issue at this point.

Instead of going through the politics of requesting more resources, I began to explore the possibility of making server-side updates and verifications directly in ES. As expected, this was actually a common issue throughout the years and the search engines keep sending everyone to the same 4 year old resources with lots of comments about how it didn't work or didn't understand how to implement it.

**Conditional update of an object in ES**

Given that we only care to keep the latest object based on the timestamp, this simplified things quite a bit. I actually read the ES [documentation][es-versioning], given the amount of questions posted in internet seems like no one has read all the way to the bottom.

I'll go straight to the point, instead of letting ES update the version of the objects, we can manage it on our own, with one nice little feature: the new version must always be greater that the previous one by any amount.

Here we decided to use the **timestamp as version**, thus guaranteeing that ES will always keep the latest object without us having to check the timestamp ourselves or even ask whether the object exists. For this we need to send the new version and let ES know that an external system is versioning the objects in its stead.

Here's a little sample that can be used to send requests to ES and try it out:
```json
POST blog/text/2?version=1640791921&version_type=external
{
    "customer": "sir-farfan",
    "notes": "for blogging purposes",
    "timestamp": 1640791921
}
```

Result
```json
{
    "_index": "blog",
    "_type": "text",
    "_id": "2",
    "_version": 1640280891,
    "result": "created",
    "_shards": {
        "total": 2,
        "successful": 1,
        "failed": 0
    },
    "_seq_no": 0,
    "_primary_term": 1
}
```

In the event that multiple updates of the same object arrived our of order, or even duplicated, ES will recognize that the version is lower that that of the object currently stored, returning a 409 *version_conflict* error back to us.
```json
{
    "error": {
        "root_cause": [
            {
                "type": "version_conflict_engine_exception",
                "reason": "[text][2]: version conflict, current version [1640280891] is higher or equal to the one provided [1640280891]",
                "index_uuid": "u8U3_J-NTvynV4usNXlyEg",
                "shard": "2",
                "index": "blog"
            }
        ],
        "type": "version_conflict_engine_exception",
        "reason": "[text][2]: version conflict, current version [1640280891] is higher or equal to the one provided [1640280891]",
        "index_uuid": "u8U3_J-NTvynV4usNXlyEg",
        "shard": "2",
        "index": "blog"
    },
    "status": 409
}
```


[source-includes]: https://www.elastic.co/guide/en/elasticsearch/reference/current/docs-get.html
[es-versioning]:   https://www.elastic.co/blog/elasticsearch-versioning-support

