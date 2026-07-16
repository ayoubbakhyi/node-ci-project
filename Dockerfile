from node:20-slim
workdir /app
copy package.json .
run npm install
copy . .
expose 3000
cmd ["node", "app.js"]
