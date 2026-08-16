# Velero restore procedure:
1. Suspend the relevant or all fluxcd kustomizations.
2. Scale down the application for which the PVC needs to be restored.
3. (If present) Remove the old to be restored PVC.
4. Run the velero create restore command: `velero create restore --from-backup ${TARGET_BACKUP} --include-namespaces ${TARGET_NAMESPACE}`
5. Scale up the application for which the PVC needs to be restored.
6. Monitor and valdiate that the restore was successfull.
7. Resume the relevant or all fluxcd kustomizations.
