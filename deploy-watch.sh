cd /home/ec2-user/autoos-deploy
while true; do
  git fetch origin main 2>/dev/null
  LOCAL=$(git rev-parse HEAD 2>/dev/null)
  REMOTE=$(git rev-parse origin/main 2>/dev/null)
  if [ "$LOCAL" != "$REMOTE" ]; then
    git pull origin main
    for FILE in *.html; do
      if [ -f "$FILE" ]; then
        aws s3 cp "$FILE" s3://rons-automotive-website/$FILE --content-type text/html
        echo "DEPLOYED: $FILE"
      fi
    done
    aws cloudfront create-invalidation --distribution-id EV5Z7DZBRS6S6 --paths '/*'
    echo "INVALIDATED"
  fi
  sleep 10
done
