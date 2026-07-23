When not running in HA mode the control plane node can be shutdown by the followin actions:
First cordon and drain the node.
Shell into the piraeus sattelite pod of the node and perform 'drbadm down all', to cleanly disconnect all of the drbadm volumes.
Now perform the shutdown are upgrade.
