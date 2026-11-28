# ---- Build stage ----
FROM node:22-alpine AS build
WORKDIR /app
COPY package.json yarn.lock ./
RUN yarn install --frozen-lockfile
COPY . .
ENV VITE_APP_API_ENDPOINT_URL=https://api.themoviedb.org/3
RUN --mount=type=secret,id=tmdb_key \
    VITE_APP_TMDB_V3_API_KEY="$(cat /run/secrets/tmdb_key)" yarn build

# ---- Runtime stage: non-root nginx ----
FROM nginxinc/nginx-unprivileged:stable-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 8080
