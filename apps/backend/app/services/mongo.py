from pymongo import MongoClient, errors


def get_mongo_status(mongo_url: str) -> tuple[bool, str]:
    client = None
    try:
        client = MongoClient(mongo_url, serverSelectionTimeoutMS=1500)
        client.admin.command("ping")
        database_name = mongo_url.rsplit("/", maxsplit=1)[-1].split("?", maxsplit=1)[0] or "platform"
        workload_count = client[database_name]["workloads"].count_documents({})
        return True, f"ping ok, workloads={workload_count}"
    except errors.PyMongoError as exc:
        return False, str(exc)
    finally:
        if client is not None:
            client.close()
