const path = require("path");

const private_key_file = process.argv[2];
const tenant = process.argv[3];

const headers = {
   algorithm: 'RS256',
   noTimestamp: true,
   expiresIn: '1h',
   keyid: path.basename(private_key_file)
}

const privateKey = require('fs').readFileSync(private_key_file);

const payload = {
    "iss": "jitsi",
    "aud": "jitsi",
    "sub": tenant,
    "context": {
        "group": tenant
    },
    "room": "*"
  }

const jwt = require('jsonwebtoken');
const token = jwt.sign(payload, privateKey, headers);
console.log(encodeURI(token))
