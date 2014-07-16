TKCoreAudioBridge
=================

A complete Core Audio example with an AUGraph, a mixer, a file player, a recorder and a generator callback.

2 years later it occured to me that I never actually wrote the simple generator - so if you use this, you have to plug in your own tone generation code in generateSamples in TKTestGenerator. Apologies. (The main purpose of this repo is to show you how to set up and use a real world, non-trivial AUGraph, so I don't feel *too* bad).
