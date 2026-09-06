from django.urls import path
from . import views

urlpatterns = [
    path('routes/', views.routes_collection, name='routes_collection'),
    path('routes/<int:route_id>/update-location/', views.update_location, name='update_location'),
    path('routes/<int:route_id>/mute/', views.mute_route, name='mute_route'),
]
