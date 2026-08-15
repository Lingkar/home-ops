
To run garage commands run it from a garage pod.
k exec --stdin --tty -n garage garage-0 -- ./garage status

k exec --stdin --tty -n garage garage-0 -- ./garage bucket create $BUCKET_NAME

k exec --stdin --tty -n garage garage-0 -- ./garage key create ${BUCKET_KEY}
k exec --stdin --tty -n garage garage-0 -- ./garage bucket allow --read --write --owner $BUCKET_NAME --key ${BUCKET_KEY}
