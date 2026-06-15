FROM node:22.22.0-bookworm-slim AS build

WORKDIR /app

ARG APP_ENV=dev

COPY package.json package-lock.json ./
COPY .env.dev .env.dev
COPY .env.prod .env.prod
RUN cp ".env.${APP_ENV}" .env
RUN npm install -g npm@latest --quiet && rm -f package-lock.json && npm install --no-audit --no-fund

COPY . .

RUN npm run build

FROM nginx:1.27-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html

EXPOSE 80
