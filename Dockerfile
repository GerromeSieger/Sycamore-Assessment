# VULNERABLE DOCKERFILE - FOR DEMONSTRATION PURPOSES ONLY
# This intentionally uses an old Node.js image with known CVEs

FROM node:14-alpine

# Running as root (security anti-pattern)
WORKDIR /usr/src/app

# Install app dependencies
COPY package*.json ./

# Install all dependencies including dev
RUN npm install && \
    npm cache clean --force

# Bundle app source
COPY . .

# Expose the application port
EXPOSE 3000

# Start the application
CMD [ "node", "index.js" ]
