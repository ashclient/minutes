"""Synthetic notes for the CI launch screenshot; never runs inside the app."""
import datetime
import json
import pathlib
import uuid
import sys

root = pathlib.Path.home() / "Library/Application Support/Minutes"
root.mkdir(parents=True, exist_ok=True)
reference = datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)
now = (datetime.datetime.now(datetime.timezone.utc) - reference).total_seconds()
notes = []
for index, title in enumerate(["Weekly product review", "Research & planning", "Team catch-up"]):
    notes.append(dict(id=str(uuid.uuid4()), title=title, createdAt=now-index*86400, updatedAt=now-index*86400,
                      notebook="Meetings", favorite=index == 0, trashed=False, audioFiles=[], transcript=[], actions=[],
                      notes="Check the feedback from this week.\nFollow up on the onboarding changes.",
                      summary="## Overview\nThe team reviewed the latest feedback, agreed on the next set of improvements, and planned a smaller release for next week.\n\n## What we discussed\n- Make the first-run experience easier to follow.\n- Keep the next release focused on the most common requests.\n- Share a draft with the team before the next review.\n\n## Next steps\n- Review the updated flow on Friday.\n- Collect feedback before the next meeting.", pipelineStatus="ready"))
if "--long-transcript" in sys.argv:
    notes[0]["transcript"] = [dict(id=str(uuid.uuid4()), seconds=i * 2, source="Microphone", text=f"Lecture segment {i}: preserve the concept, definition and its complete worked example.") for i in range(10000)]
(root / "meetings.json").write_text(json.dumps(dict(version=1, meetings=notes)))
