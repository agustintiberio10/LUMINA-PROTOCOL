FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm install --legacy-peer-deps --production
COPY . .
EXPOSE 8080
CMD ["node", "src/index.js"]
