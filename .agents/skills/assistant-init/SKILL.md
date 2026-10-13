---
name: assistant initialization
description: Initialize an assistant that has no configuration or no daily schedule.
---

This skill walks the user through a process to setup his personal assistant initially.

# The .state directory

If not existing, create the directory .state.

# Daily schedule

Ask the user to write down its daily schedule.
That contains all tasks and appointments that occur daily or weekly or
otherwise regularly but are not contained in the user's calender
entries.
Explain the format used for scheduled tasks, so the user can add such tasks as well.

Once the user provided this schedule store that as the daily schedule.

# Configuration

Ask the user to provide the configuration of his personal assistant.
For that go through the default configuration file and ask the user to
provide the respective information.
Store the result in the configuration file.

# Finish

After successfully initializing the personal agent tell the user to
start a new session and greet his assistant.
