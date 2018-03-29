# Gerrit integration for Slack

## What is it?

A daemon that sends updates to Slack channels as noteworthy events happen on Gerrit:

  * Passing builds (except WIPs)
  * Code/QA/Product reviews
  * Comments
  * Merges
  * Failed builds (sent to owner via slackbot DM)

Also daemon add comment to JIRA ticket about patchset created and try to move
ticket in ToBuild state (state ID is hardcoded) after merge.

Review in Gerrit should have line like this `Issue: PROJ-5` where `PROJ-5` is ID in JIRA.

Tested with Gerrit 2.14.7, Slack and cloud JIRA on March 2018

## Known issues
Sometimes create a lot of ssh zombie process. Workaround is every day restart at night.

## Configuration

Sample configuration files are provided in `config`.

### slack.yml

Configure your team name and Incoming Webhook integration token here.

### gerrit.yml

Set the SSH command used to monitor stream-events on gerrit.

### channels.yml

This is where the real fun happens. The structure is as follows:

    channel1:
      project:
        - project1*


This configuration would post **all** updates from project1 to channel1, likewise for project2 and channel2. Updates to project3 are only posted to channel2 if the change owner is among those listed.

For channels that hate fun, you can turn celebratory emojis off by setting emoji to false.

    channel1:
      emoji: false

### aliases.yml

In order to ping a user on slack (e.g. for DMs on failed builds, or to @mention them), we need to know their Slack username. By default we assume the gerrit name is equal to the slack name. You can override this behavior on a per-user basis in aliases.yml.

## Running the daemon

    bundle install
    bin/gerrit-slack

## Development mode

Run the integration with DEVELOPMENT set to true to see more debug output and to *not* actually send updates to Slack.

    DEVELOPMENT=1 bin/gerrit-slack
